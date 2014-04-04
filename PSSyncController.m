//
//  SKSyncController.m
//  stky
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <Parse/Parse.h>
#import "PSSyncController.h"
#import "PSModel.h"

@interface PSSyncController ()
{
    int currentlyPullingFromServer; // Represents the number of outstanding server pull operations. @todo better way?
    int currentlyPushingToServer;
    NSTimer *pullTimer;
    NSTimer *pushTimer;
    BOOL isRunning;
}

@property (nonatomic) NSDate *lastServerSyncDate;

@property (strong, nonatomic) NSMutableSet *syncedEntityNames;
@property (strong, nonatomic) NSMutableSet *pullQueries;
@property (strong, nonatomic) NSMutableSet *pushQueries;

// Core sync operations
- (void)pullFromServer;
- (void)pushToServer;

// Callbacks tied to core sync operations
- (void)localDataChanged: (NSNotification *)n;
- (void)serverDataReceived: (NSArray *)data error:(NSError *)error;

// Batch object helpers
- (void)processChangedObjectsInChangeDictionary:(NSDictionary *)dict action:(NSString *)action;
- (void)pushLocalObjects:(NSArray *)localObjects;
- (void)saveResolvedServerObject:(PFObject *)serverObject forLocalObject:(PSModel *)localObject;
- (void)saveLocalData; // Saves without pushing

// Single-object helpers
- (PSModel *)localObjectWithId: (NSString *)docId class: (NSString *)docClass;
- (void)copyObject:(PSModel *)object toServerObject:(PFObject *)serverObject;
- (void)copyObject:(PSModel *)object fromServerObject:(PFObject *)serverObject;

@end

static PSSyncController *_sharedSyncControllerInstance = nil;

#define PSPrefKeyLastServerSync @"PSPrefKeyLastServerSync"
#define PSSyncControllerKeyshouldPushLocalChangesToServer @"PSSyncControllerKeyshouldPushLocalChangesToServer"
#define PSSyncControllerDefaultPullIntervalInMinutes 1
#define PSSyncControllerDefaultPushIntervalInMinutes 0.08


@implementation PSSyncController

@synthesize managedObjectContext = _managedObjectContext;
@synthesize syncedEntityNames = _syncedEntityNames;
@synthesize pullQueries = _pullQueries;
@synthesize pushQueries = _pushQueries;
@synthesize isSavingSyncedChanges = _isSavingSyncedChanges;

@synthesize pullIntervalInMinutes = _pullIntervalInMinutes;
@synthesize pushIntervalInMinutes = _pushIntervalInMinutes;




#pragma mark - Singleton stuff

+ (PSSyncController *)sharedInstance
{
    if (!_sharedSyncControllerInstance) {
        _sharedSyncControllerInstance = [[super allocWithZone:NULL] init];
    }
    return _sharedSyncControllerInstance;
}

+ (id)allocWithZone:(NSZone *)zone
{
    return [self sharedInstance];
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}


#pragma mark - Setup

/**
 * Initializes with a supplied managed object context.
 */
- (id)init
{
    self = [super init];
    if (self) {
        _isSavingSyncedChanges = NO;
        currentlyPullingFromServer = 0;
        currentlyPushingToServer = 0;
    }
    return self;
}


/**
 * By default nothing gets synced. Users of this class can add individual
 * core data entities for syncing via this method. May be called before or
 * after sync has started.
 */
- (void)addEntity:(NSString *)entityName
{
    // Add a pull query to grab updates from the server
    PFQuery *pullQuery = [PFQuery queryWithClassName:entityName];
    
    pullQuery.limit = NSIntegerMax; // @todo let this run in batches if necessary? or something?
    
    if (!pullQuery) {
        SKLog(YES, @"Error: Unable to create pull query for entity %@.", entityName);
    }
    else {
        if (!self.pullQueries) {
            self.pullQueries = [NSMutableSet setWithCapacity:1];
            self.pushQueries = [NSMutableSet setWithCapacity:1];
            self.syncedEntityNames = [NSMutableSet setWithCapacity:1];
        }
        [self.pullQueries addObject:pullQuery];
        [self.syncedEntityNames addObject:entityName];
    }
    
    // Add a push query to push updates to the server
    NSFetchRequest *fetchReq = [[NSFetchRequest alloc] init];
    fetchReq.entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:self.managedObjectContext];
    fetchReq.predicate = [NSPredicate predicateWithFormat:@"(serverPushAction != '') AND (serverPushAction != nil)"];
    [self.pushQueries addObject:fetchReq];
}


/**
 * Start syncing. No actual data sync happens until this is called.
 */
- (void)start
{
    isRunning = YES;
    
    // Grab the latest from the server and start periodic pulling
    [self pullFromServer];
    pullTimer = [NSTimer scheduledTimerWithTimeInterval:self.pullIntervalInMinutes * 60  target:self selector:@selector(pullFromServer) userInfo:nil repeats:YES];
    
    // Push changes to the server and start periodic pushing
    [self pushToServer];
    pushTimer = [NSTimer scheduledTimerWithTimeInterval:self.pushIntervalInMinutes*60 target:self selector:@selector(pushToServer) userInfo:nil repeats:YES];
    
    // Register to pull when the app activates. Not pushing here since it'll happen a couple seconds later.
    // @todo Don't sync if we've just switched away and back quickly.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pullFromServer) name:SKNotificationAppDidBecomeActive object:nil];
}

- (void)stop
{
    isRunning = NO;
    
    [pullTimer invalidate];
    pullTimer = nil;
    
    [pushTimer invalidate];
    pushTimer = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SKNotificationAppDidBecomeActive object:nil];
    
    // @todo - May still be some race conditions, e.g., we invalidate the timers but operations are 
    // running on separate threads. isRunning should help but may not be a complete solution.
}




#pragma mark - Core sync operations

/**
 * Grab any updates since the last server pull, and prepare to sync them when received.
 */
- (void)pullFromServer
{
    if (isRunning && !currentlyPullingFromServer) {
        if ([PFUser currentUser]) {
            for (PFQuery *q in self.pullQueries) {
                currentlyPullingFromServer++; // Avoid running multiple pull operations simultaneously.
                [q whereKey:@"updatedAt" greaterThan:self.lastServerSyncDate]; // @todo Am I stacking where keys on top of each other in an unfortunate manner?
                [q findObjectsInBackgroundWithTarget:self selector:@selector(serverDataReceived:error:)];
            }
        }
    }
}


/**
 * Push any local objects that haven't been pushed since their last update.
 */
- (void)pushToServer
{
    if (isRunning && !currentlyPushingToServer && !currentlyPullingFromServer && [PFUser currentUser]) {
        // A running pull blocks a push, but not vice versa.
        for (NSFetchRequest *fetchReq in self.pushQueries) {
            currentlyPushingToServer++;
            
            // Fetch queued objects for this entity.
            NSError *error = nil;
            NSArray *queuedLocalObjects = [self.managedObjectContext executeFetchRequest:fetchReq error:&error];
            if (!queuedLocalObjects) {
                SKLog(YES, @"Error fetching changed tasks.");
                return;
            }
            
            if (queuedLocalObjects.count) {
                SKLog(YES, @"Pushing %d queued objects.", queuedLocalObjects.count);
                
                [self pushLocalObjects:queuedLocalObjects];
            }
            currentlyPushingToServer--; // @todo May not be useful given how asynchronously this is happening
        }
    }
}




#pragma mark - Core sync callbacks


/**
 * Core data notification handler to let us know when local data has changed.
 */
- (void)localDataChanged:(NSNotification *)n
{
    if (isRunning) {
        // If the notification was generated in the course of the sync controller itself
        // saving data, don't push it, but do clear that flag.
        if (_isSavingSyncedChanges) {
            _isSavingSyncedChanges = NO;
            return;
        }
        SKLog(NO, @"Pushing changed local data.");
        
        NSDictionary *changes = n.userInfo;
        [self processChangedObjectsInChangeDictionary:changes action:NSDeletedObjectsKey];
        [self processChangedObjectsInChangeDictionary:changes action:NSInsertedObjectsKey];
        [self processChangedObjectsInChangeDictionary:changes action:NSUpdatedObjectsKey];    
    }
}


/**
 * Called when a server pull request comes back. Takes care of the bulk of
 * a server pull operation.
 */
- (void)serverDataReceived:(NSArray *)data error:(NSError *)error
{
    if (isRunning) {
        if (error) {
            SKLog(YES, @"Server pull error: %@", error.description);
            return;
        }

        BOOL changedALocalObject = NO; // Set to YES when the returned data results in a local change that needs saving.
        
        // @todo Right now, a local change that gets pushed to the server auto-updates the server's updatedAt field. This results
        // in that same change coming back down as a server change. We prevent an infinite loop client-side so it's not destructive
        // in any way, but it is extra network traffic.
        
        if (data.count) SKLog(NO, @"Received %d server changes.", data.count);
        for (PFObject *serverObject in data) {
            
            // Find the corresponding Core Data object
            PSModel *localObject = [self localObjectWithId:[serverObject valueForKey:@"docId"] class:[serverObject className]];
            
            if ([[serverObject valueForKey:@"docDeleted"] boolValue]) {
                // Object was deleted on the server
                if (localObject) {
                    if ([localObject compareVersionWithServerObject:serverObject] == NSOrderedDescending) {
                        // Local object is newer. Any change always trumps deletion, 
                        // so throw out deletion and queue local object to push.
                        [localObject pushToServerWithAction:SKUndeletedObjectsKey];
                    } else {
                        [self.managedObjectContext deleteObject:localObject];
                        changedALocalObject = YES;
                    }
                }
                else { // Local object not found.
                    // @todo Again, not sure how to prevent locally-originated changes from coming back down
                    // from server. It's extra traffic but not destructive in any way.
                }
            } else {
                // Object was updated or inserted on server
                if (localObject) {
                    // Local object exists, so it's an update
                    NSComparisonResult versionComparison = [localObject compareVersionWithServerObject:serverObject];
                    
                    if (versionComparison == NSOrderedDescending) {
                        // Local object is newer, so update server object instead and throw out server change
                        [localObject pushToServerWithAction:NSUpdatedObjectsKey];
                    } else if (versionComparison == NSOrderedAscending) {
                        // Server object is newer, so update local object from it
                        [self copyObject:localObject fromServerObject:serverObject];
                        changedALocalObject = YES;
                    }
                    // Else do nothing with server change or local chage
                } else {
                    // No local object and this isn't a deletion, so assume newly 
                    // inserted server object and copy server data over.
                    localObject = (PSModel *)[NSEntityDescription insertNewObjectForEntityForName:[serverObject className] inManagedObjectContext:self.managedObjectContext];
                    [self copyObject:localObject fromServerObject:serverObject];
                    changedALocalObject = YES;
                }
            }
        }

        // Save any changes, blocking the push that would otherwise result.
        if (changedALocalObject) {
            [self saveLocalData];
            [[NSNotificationCenter defaultCenter] postNotificationName:PSNotificationLocalObjectsUpdatedFromServer object:self];
        }
        
        self.lastServerSyncDate = [NSDate date];
        
        // Decrement counter to indicate we're done syncing this entity. 
        // Will hit 0 when all entities finish this callback.
        currentlyPullingFromServer--;
    }
}




#pragma mark - Batch object operations


/**
 * Takes the dictionary of changed objects that Core Data provides and deals with those from
 * a single type of change. Deletions are pushed to server immediately, at least for now, while
 * anything else is queued.
 */
- (void)processChangedObjectsInChangeDictionary:(NSDictionary *)dict action:(NSString *)action
{
    NSSet *obs = [dict objectForKey:action];
    BOOL isDelete = [action isEqualToString:NSDeletedObjectsKey];
    for (PSModel *ob in obs) {
        if ([self.syncedEntityNames containsObject:ob.entity.name]) {
            // @todo Maybe queue deletions too. Not currently queued because it would require
            // a more robust queuing mechanism (can't query for objects already deleted).
            if (isDelete) [ob deleteOnServer]; 
            else [ob pushToServerWithAction:action];
        }
    }
}


/**
 * Given an array of local objects queued to push, locate and push the corresponding server
 * objects.
 *
 * @todo: This currently calls the server to get the server objects. Be nice to avoid that.
 *
 * @todo: Due to the above issue and my lack of familiarity with thread-safe operations,
 * this currently makes one server call per object, creating all kinds of asynchronous messiness
 * and extra network traffic. Be nice to fix that...
 *
 * Note that this method checked modification dates to ensure that the local changes are
 * newer than the server objects. As such, the number of objects returned may be less than
 * the number supplied.
 */
- (void)pushLocalObjects:(NSArray *)localObjects
{
    for (PSModel *ob in localObjects) {
        NSString *action = ob.serverPushAction;
        
        if ([action isEqualToString:NSInsertedObjectsKey]) {
            // We're inserting. Create new server object, making sure to set its ownership.
            PFObject *serverObject = [PFObject objectWithClassName:ob.entity.name];
            serverObject.ACL = [PFACL ACLWithUser:[PFUser currentUser]];
            [self copyObject:ob toServerObject:serverObject];
            [self saveResolvedServerObject:serverObject forLocalObject:ob];
        }
        else {
            // We're performing some other action. Grab existing server object.
            PFQuery *query = [PFQuery queryWithClassName:ob.entity.name];
            [query whereKey:@"docId" equalTo:ob.docId];
            currentlyPushingToServer++;
            [query findObjectsInBackgroundWithBlock:^(NSArray *returnedServerObjects, NSError *error) {
                if (error) SKLog(YES, @"Model sync error: %@ %@", error, error.userInfo);
                
                else if (returnedServerObjects.count > 1) {
                    SKLog(YES, @"Model sync error: found multiple objects for single doc ID.");

                } else if (returnedServerObjects.count) {
                    PFObject *serverObject = [returnedServerObjects objectAtIndex:0];
                    
                    // @todo I'm basically running two unidirectional syncs in parallel. Maybe 
                    // a way to consolidate?
                    
                    if ([ob compareVersionWithServerObject:serverObject] == NSOrderedDescending) {
                        // Local object is newer
                        if ([action isEqualToString:NSDeletedObjectsKey] || [action isEqualToString:SKUndeletedObjectsKey]) {
                            // Queued object was either deleted by the user or is queued for server undeletion
                            // as a part of the sync process (i.e. user altered the object here after
                            // deleting elsewhere). Either way we change the deletion flag. (We're not 
                            // deleting objects on the server so we can track changes for other clients someday.)
                            BOOL newDeletionValue = [action isEqualToString:NSDeletedObjectsKey] ? YES : NO;
                            [serverObject setValue:[NSNumber numberWithBool:newDeletionValue] forKey:SKModelServerKeyDeleted];
                            [self saveResolvedServerObject:serverObject forLocalObject:ob];
                        }
                        else {
                            // It's a simple update action
                            [self copyObject:ob toServerObject:serverObject];
                            [self saveResolvedServerObject:serverObject forLocalObject:ob];
                        }
                    }
                }
                else {
                    SKLog(YES, @"Sync issue: object should exist but doesn't. This shouldn't happen...");
                    
                    // Turn into an insert and push the next time. Better to keep the local object than not.
                    // @todo debug better?
                    ob.serverPushAction = NSInsertedObjectsKey;
                }
                currentlyPushingToServer--;
            }];
        }
    }
}


/**
 * Does the actual work of taking a server object and pushing it to the server, and then on
 * success clearing the queued flag for the corresponding (supplied) local object.
 */
- (void)saveResolvedServerObject:(PFObject *)serverObject forLocalObject:(PSModel *)localObject
{
    currentlyPushingToServer++;
    [serverObject saveInBackgroundWithBlock:^(BOOL succeeded, NSError *error) {
        if (succeeded) {
            // Pushed successfully so we can unqueue the local object.
            [localObject unqueueForServerPush];
            [self saveLocalData];
        } else {
            // Push failed, presumably via a network error. Keep queued for next try.
            SKLog(YES, @"Error pushing local data to server: %@", error.description);
        }
        currentlyPushingToServer--;
    }];
}



#pragma mark - Object-level operations


/**
 * Take the values in a local object and use them to update a server object.
 */
- (void)copyObject:(PSModel *)object toServerObject:(PFObject *)serverObject
{    
    NSDictionary *modelAttrs = object.entity.attributesByName;
    for (NSString *attr in modelAttrs) {
        if (![PSModel shouldIgnoreAttribute:attr pushing:YES]) {
            id val = [object valueForKey:attr];
            if (val == nil) val = [NSNull null];
            [serverObject setObject:val forKey:attr];
        }
    }
    [serverObject setObject:[[PFUser currentUser] username]  forKey:@"docOwner"]; // @todo Necessary?
}


/**
 * Take the values in a server object and use them to update a local one.
 */
- (void)copyObject:(PSModel *)object fromServerObject:(PFObject *)serverObject
{
    // If server object lacks docId, use objectId instead and copy it over.
    // This assumes we never have a server object with empty docId for which there's
    // a corresponding local object with docId. Not sure how we'd match those up anyway.
    NSString *serverDocId = [serverObject valueForKey:@"docId"];
    if (!serverDocId || [serverDocId isEqualToString:@""]) {
        [serverObject setValue:serverObject.objectId forKey:@"docId"];
        [serverObject saveEventually];
    }
    
    NSDictionary *modelAttrs = object.entity.attributesByName;
    for (NSString *attr in modelAttrs) {
        if (![PSModel shouldIgnoreAttribute:attr pushing:NO]) {
            id val = [serverObject valueForKey:attr];
            if (val == [NSNull null]) val = nil;
            [object setValue:val forKey:attr];
        }
    }
}




#pragma mark - Internal helpers


/**
 * Get/set the timestamp for last sync. Used to determine which objects require a pull.
 * @todo Potential issue here when client and server clocks are out of sync?
 */
- (void)setLastServerSyncDate:(NSDate *)lastServerSyncDate
{
    [[NSUserDefaults standardUserDefaults] setObject:lastServerSyncDate forKey:PSPrefKeyLastServerSync];
}

- (NSDate *)lastServerSyncDate
{
    if (![[NSUserDefaults standardUserDefaults] objectForKey:PSPrefKeyLastServerSync]) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSDate distantPast]  forKey:PSPrefKeyLastServerSync];
    }
    return [[NSUserDefaults standardUserDefaults] objectForKey:PSPrefKeyLastServerSync];
}


/**
 * Given a doc ID, get the corresponding local object in a given class (entity).
 */
- (PSModel *)localObjectWithId: (NSString *)docId class:(NSString *)docClass
{
    NSFetchRequest *fetchReq = [[NSFetchRequest alloc] init];
    fetchReq.entity = [NSEntityDescription entityForName:docClass inManagedObjectContext:self.managedObjectContext];
    fetchReq.predicate = [NSPredicate predicateWithFormat:@"docId == %@", docId];
    
    NSError *error = nil;
    NSArray *result = [self.managedObjectContext executeFetchRequest:fetchReq error:&error];
    
    if (!result) {
        SKLog(YES, @"Error fetching task corresponding to server-side object.");
        return nil;
    }
    
    if (result.count > 1) {
        // This shouldn't happen.
        SKLog(YES, @"Error: Somehow got multiple local docs back with the same ID.");
        return nil;
    }
    
    if (result.count) {
        // We got a match
        return [result objectAtIndex:0];
    }
    
    // No match.
    return nil;
}


/**
 * Determines how frequently we grab updates from the server.
 */
- (float)pullIntervalInMinutes
{
    if (!_pullIntervalInMinutes) _pullIntervalInMinutes = PSSyncControllerDefaultPullIntervalInMinutes;
    return _pullIntervalInMinutes;
}


/**
 * Determines how frequently we send updates to the server.
 */
- (float)pushIntervalInMinutes
{
    if (!_pushIntervalInMinutes) _pushIntervalInMinutes = PSSyncControllerDefaultPullIntervalInMinutes;
    return _pushIntervalInMinutes;
}


/**
 * Returns the managed object context we're syncing. Defaults to the Apple standard.
 */
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext) return _managedObjectContext;
    
    // If managed object context isn't set try Apple's default
    id appDelegate = [[UIApplication sharedApplication] delegate];
    if ([appDelegate respondsToSelector:@selector(managedObjectContext)]) {
        [self setManagedObjectContext:[appDelegate managedObjectContext]];
        return _managedObjectContext;
    }
    
    // If here, nothing available
    SKLog(YES, @"Error: Sync controller has no managed object context.");
    return nil;
}

/**
 * Setter for managed object context. Also registers for notifications.
 */
- (void)setManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_managedObjectContext) {
        [nc removeObserver:self name:NSManagedObjectContextDidSaveNotification object:_managedObjectContext];
    }
    _managedObjectContext = managedObjectContext;
    [nc addObserver:self selector:@selector(localDataChanged:) name:NSManagedObjectContextDidSaveNotification object:_managedObjectContext];
}


/**
 * Internal operation for saving local Core Data objects. Blocks the resulting
 * notification from triggering server push.
 */
- (void)saveLocalData
{
    _isSavingSyncedChanges = YES;
    if ([[[UIApplication sharedApplication] delegate] respondsToSelector:@selector(TEMPsaveContext)]) {
        [[[UIApplication sharedApplication] delegate] performSelector:@selector(TEMPsaveContext)];
    } else {
        NSError *err = nil;
        BOOL saved = [self.managedObjectContext save:&err];
        if (!saved)
            SKLog(YES, @"Error saving local data during sync: %@", err.description);
    }
}
                 
                 
@end
