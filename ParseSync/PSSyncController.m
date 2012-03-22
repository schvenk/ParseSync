//
//  PSSyncController.m
//  ParseSync
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 Dave Feldman. 
//  Licensed under the MIT License (http://www.opensource.org/licenses/mit-license.html).
//

#import <Parse/Parse.h>
#import "PSSyncController.h"
#import "SKAppDelegate.h"
#import "PSModel.h"

@interface PSSyncController ()
{
    int currentlyPullingFromServer; // Represents the number of outstanding server pull operations. @todo better way?
    int currentlyPushingToServer;
}
@property (nonatomic) NSDate *lastServerSyncDate;
@property (nonatomic, readonly) NSDate *firstRunDate; // @todo Remove before 1.0?
@property (strong, nonatomic) NSMutableSet *pullQueries;
@property (strong, nonatomic) NSMutableSet *syncedEntityNames;
@property (strong, nonatomic) NSManagedObjectContext *managedObjectContext;
@property (nonatomic) BOOL shouldPushToServer;

- (void)pullFromServer;
- (void)pushToServer;

- (void)localDataChanged: (NSNotification *)n;
- (void)serverDataReceived: (NSArray *)data error:(NSError *)error;
- (PSModel *)localObjectWithId: (NSString *)docId class: (NSString *)docClass;

- (void)pushObjectToServer:(PSModel *)object withAction:(NSString *)action;
- (void)copyObject:(PSModel *)object toServerObject:(PFObject *)serverObject;
- (void)copyObject:(PSModel *)object fromServerObject:(PFObject *)serverObject;


@end

#define SKPrefKeyLastServerSync @"lastServerSync"
#define SKPrefKeyFirstRunDate @"SKPrefKeySyncControllerFirstRunDate"
#define SKSyncControllerKeyShouldPushToServer @"SKSyncControllerKeyShouldPushToServer"
#define SKSyncControllerDefaultSyncIntervalInMinutes 0.1

@implementation PSSyncController
@synthesize pullQueries = _pullQueries;
@synthesize syncIntervalInMinutes = _syncIntervalInMinutes;
@synthesize syncedEntityNames = _syncedEntityNames;
@synthesize managedObjectContext = _managedObjectContext;
@synthesize shouldPushToServer = _shouldPushToServer;


#pragma mark - Setup

- (id)initWithManagedObjectContext:(NSManagedObjectContext *)context
{
    self = [super init];
    if (self) {
        self.shouldPushToServer = YES;
        self.managedObjectContext = context;
        currentlyPullingFromServer = 0;
        currentlyPushingToServer = 0;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(localDataChanged:) name:NSManagedObjectContextDidSaveNotification object:self.managedObjectContext];
    }
    return self;
}

- (id)init
{
    return [self initWithManagedObjectContext:nil];
}


- (void)syncEntity:(NSString *)entityName
{
    PFQuery *pullQuery = [PFQuery queryWithClassName:entityName];
    if (!pullQuery) {
        NSLog(@"Error: Unable to create pull query for entity %@.", entityName);
    }
    else {
        if (!self.pullQueries) {
            self.pullQueries = [NSMutableSet setWithCapacity:1];
            self.syncedEntityNames = [NSMutableSet setWithCapacity:1];
        }
        [self.pullQueries addObject:pullQuery];
        [self.syncedEntityNames addObject:entityName];
    }
}

- (void)start
{
    // @todo remove before 1.0?
    if (!self.firstRunDate) { 
        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:SKPrefKeyFirstRunDate];
    }

    [self pullFromServer];
    [NSTimer scheduledTimerWithTimeInterval:self.syncIntervalInMinutes * 60  target:self selector:@selector(pullFromServer) userInfo:nil repeats:YES];
    
    // Register to sync when the app activates
    // @todo Don't sync if we've just switched away and back quickly.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pullFromServer) name:SKNotificationAppDidBecomeActive object:nil];
}



#pragma mark - Core sync operations

- (void)pullFromServer
{
    if (!currentlyPullingFromServer) {
        if ([PFUser currentUser]) {
            NSLog(@"Pulling from server.");
            for (PFQuery *q in self.pullQueries) {
                currentlyPullingFromServer++; // Avoid running multiple pull operations simultaneously. @todo Better way?
                [q whereKey:@"updatedAt" greaterThan:self.lastServerSyncDate]; // @todo Am I stacking where keys on top of each other in an unfortunate manner?
                [q findObjectsInBackgroundWithTarget:self selector:@selector(serverDataReceived:error:)];
            }
        }
    }
}

- (void)pushToServer
{
    if (!currentlyPushingToServer) {
        if ([PFUser currentUser]) {
            NSLog(@"Pushing to server.");
            for (NSString *entityName in self.syncedEntityNames) {
                currentlyPushingToServer++;
                
                NSFetchRequest *fetchReq = [[NSFetchRequest alloc] init];
                fetchReq.entity = [NSEntityDescription entityForName:entityName inManagedObjectContext:self.managedObjectContext];
                fetchReq.predicate = [NSPredicate predicateWithFormat:@"needsServerPush == TRUE"];
                
                NSError *error = nil;
                NSArray *result = [self.managedObjectContext executeFetchRequest:fetchReq error:&error];
                
                if (!result) {
                    NSLog(@"Error fetching changed tasks.");
                    return;
                }
                
                if (result.count) {
                    NSLog(@"Pushing %d changed tasks.", result.count);
                    
                }
            
            }
        }
    }
}


#pragma mark - Notification callbacks

- (void)localDataChanged:(NSNotification *)n
{
    // Was this save generated by a server change? If so, ignore.
    if (!self.shouldPushToServer) {
        NSLog(@"Not pushing changed local data.");
        self.shouldPushToServer = YES;
        return;
    }
    NSLog(@"Pushing changed local data.");
    
    NSDictionary *changes = n.userInfo;
    [self pushChangedObjectsInChangeDictionary:changes action:NSDeletedObjectsKey];
    [self pushChangedObjectsInChangeDictionary:changes action:NSInsertedObjectsKey];
    [self pushChangedObjectsInChangeDictionary:changes action:NSUpdatedObjectsKey];    
}

- (void)pushChangedObjectsInChangeDictionary:(NSDictionary *)dict action:(NSString *)action
{
    NSSet *obs = [dict objectForKey:action];
    for (PSModel *ob in obs) {
        if ([self.syncedEntityNames containsObject:ob.entity.name]) {
            [self pushObjectToServer:ob withAction:action];
        }
    }
}

- (void)serverDataReceived: (NSArray *)data error:(NSError *)error
{
    BOOL changedALocalObject = NO;
    
    // @todo prevent client-originated changes from reading as server-based ones.
    if (data.count) NSLog(@"Received %d server changes.", data.count);
    for (PFObject *serverObject in data) {
        // Find the corresponding Core Data object
        PSModel *localObject = [self localObjectWithId:[serverObject valueForKey:@"docId"] class:[serverObject className]];
        
        if ([[serverObject valueForKey:@"docDeleted"] boolValue]) {
            // Object was deleted on the server
            if (localObject) {
                [self.managedObjectContext deleteObject:localObject];
                changedALocalObject = YES;
            }
            else {
                // @todo Not sure how to prevent locally-originated changes from coming back down
                // from server. It's extra traffic but not destructive in any way.
                //NSLog(@"(Attempt to delete nonexistent local object.)");
            }
        } else {
            if (!localObject) {
                // No local object and this isn't a deletion, so assume new object.
                localObject = (PSModel *)[NSEntityDescription insertNewObjectForEntityForName:[serverObject className] inManagedObjectContext:self.managedObjectContext];
            }
            
            // Now we have either a preexisting or newly created local object.
            [self copyObject:localObject fromServerObject:serverObject];
            changedALocalObject = YES;
        }
    }
    
    if (changedALocalObject) {
        // Update context's user info to indicate we shouldn't post to server after this save
        self.shouldPushToServer = NO;
        
        NSError *err = nil;
        BOOL saved = [self.managedObjectContext save:&err];
        if (!saved)
            NSLog(@"Error saving after deleting a task during sync.");
    }
    
    self.lastServerSyncDate = [NSDate date];
    currentlyPullingFromServer--;
}



#pragma mark - Object-level operations

- (void)pushObjectToServer:(PSModel *)object withAction:(NSString *)action
{
    if ([action isEqualToString:NSInsertedObjectsKey]) {
        PFObject *serverObject = [PFObject objectWithClassName:object.entity.name];
        serverObject.ACL = [PFACL ACLWithUser:[PFUser currentUser]];
        [self copyObject:object toServerObject:serverObject];
    }
    else {
        PFQuery *query = [PFQuery queryWithClassName:object.entity.name];
        [query whereKey:@"docId" equalTo:object.docId];
        [query findObjectsInBackgroundWithBlock:^(NSArray *objects, NSError *error) {
            if (error) NSLog(@"Model sync error: %@ %@", error, error.userInfo);
            
            else if (objects.count > 1) {
                NSLog(@"Model sync error: found multiple objects for single doc ID.");
            }
            else if (objects.count) {
                PFObject *serverObject = [objects objectAtIndex:0];
                
                if ([action isEqualToString:NSDeletedObjectsKey]) {
                    // We're not actually deleting objects on the server, so we can use them to track the changes
                    // for other clients someday
                    [serverObject setValue:[NSNumber numberWithBool:YES] forKey:SKModelServerKeyDeleted];
                    [serverObject saveEventually];
                }
                else {
                    // Copy updated data and save
                    [self copyObject:object toServerObject:serverObject];
                }
            }
            else {
                // Presumably we're dealing with a race condition: object has yet to be inserted server-side by
                // another operation pending or in progress. Defer this operation.
                /*[NSTimer scheduledTimerWithTimeInterval:SKModelPushSleepTimerDurationInSeconds target:self selector:@selector(pullFromServer) userInfo:action repeats:NO];*/
                // Originally there was a deferred server push method in SKModel that was probably intended as the selector for the code above
#warning implement this
            }
        }];
    }
}

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
    [serverObject saveEventually];
}

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
    
    // Note that we don't save here, relying on the caller instead.
}



#pragma mark - Internal helpers

- (void)setLastServerSyncDate:(NSDate *)lastServerSyncDate
{
    [[NSUserDefaults standardUserDefaults] setObject:lastServerSyncDate forKey:SKPrefKeyLastServerSync];
}
- (NSDate *)lastServerSyncDate
{
    if (![[NSUserDefaults standardUserDefaults] objectForKey:SKPrefKeyLastServerSync]) {
        [[NSUserDefaults standardUserDefaults] setObject:[NSDate distantPast]  forKey:SKPrefKeyLastServerSync];
    }
    return [[NSUserDefaults standardUserDefaults] objectForKey:SKPrefKeyLastServerSync];
}

- (NSDate *)firstRunDate
{
    return [[NSUserDefaults standardUserDefaults] objectForKey:SKPrefKeyFirstRunDate];
}

- (PSModel *)localObjectWithId: (NSString *)docId class:(NSString *)docClass
{
    NSFetchRequest *fetchReq = [[NSFetchRequest alloc] init];
    fetchReq.entity = [NSEntityDescription entityForName:docClass inManagedObjectContext:self.managedObjectContext];
    fetchReq.predicate = [NSPredicate predicateWithFormat:@"docId == %@", docId];
    
    NSError *error = nil;
    NSArray *result = [self.managedObjectContext executeFetchRequest:fetchReq error:&error];
    
    if (!result) {
        NSLog(@"Error fetching task corresponding to server-side object.");
        return nil;
    }
    
    if (result.count > 1) {
        // This shouldn't happen.
        NSLog(@"Error: Somehow got multiple local docs back with the same ID.");
        return nil;
    }
    
    if (result.count) {
        // We got a match
        return [result objectAtIndex:0];
    }
    
    // No match.
    return nil;
}

- (float)syncIntervalInMinutes
{
    if (!_syncIntervalInMinutes) _syncIntervalInMinutes = SKSyncControllerDefaultSyncIntervalInMinutes;
    return _syncIntervalInMinutes;
}

- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext) return _managedObjectContext;
    
    // If managed object context isn't set try Apple's default
    id appDelegate = [[UIApplication sharedApplication] delegate];
    if ([appDelegate respondsToSelector:@selector(managedObjectContext)]) {
        return [appDelegate managedObjectContext];
    }
    
    // If here, nothing available
    NSLog(@"Error: Sync controller has no managed object context.");
    return nil;
}

@end
