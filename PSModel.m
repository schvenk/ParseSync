//
//  SKModel.m
//  stky
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import "PSModel.h"
#import "PSSyncController.h"

@interface PSModel ()
- (void)createDocId;
@end

@implementation PSModel

@dynamic createdAt;
@dynamic updatedAt;
@dynamic docId;
@dynamic serverPushAction;
@dynamic docVersion;


+ (BOOL)shouldIgnoreAttribute:(NSString *)attr pushing:(BOOL)pushing
{
    static NSSet *ignoredAttrsPush;
    static NSSet *ignoredAttrsPull;
    if (!ignoredAttrsPush) ignoredAttrsPush = [NSSet setWithObjects:@"createdAt", @"updatedAt", @"objectId", @"docDeleted", @"serverPushAction", nil];
    if (!ignoredAttrsPull) ignoredAttrsPull = [NSSet setWithObjects:@"objectId", @"docDeleted", @"docOwner", @"serverPushAction", nil];
    
    NSSet *testSet = pushing ? ignoredAttrsPush : ignoredAttrsPull;
    return [testSet containsObject:attr];
}


- (void)awakeFromInsert
{
    [super awakeFromInsert];
    self.createdAt = [NSDate date];
    self.docVersion = [NSNumber numberWithInt:0];
    [self createDocId];
}


- (void)willSave
{
    if (!self.createdAt) [self setPrimitiveValue:[NSDate date] forKey:@"createdAt"]; // @todo For backward compatibility with early alphas
    [self setPrimitiveValue:[NSDate date] forKey:@"updatedAt"];
    if (![[PSSyncController sharedInstance] isSavingSyncedChanges]) {
        [self setPrimitiveValue:[NSNumber numberWithInt:[self.docVersion intValue]+1]  forKey:@"docVersion"];
    }
    [super willSave];
}


- (void)createDocId
{
    self.docId = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, CFUUIDCreate(kCFAllocatorDefault));
}


/**
 * Delete this object on the server. Right now we're queuing most changes
 * to occur via batch operation but deletions happen immediately, since
 * our queuing approach of setting a flag wouldn't work with them
 * (can't query Core Data for an object already deleted).
 */
- (void)deleteOnServer
{
    PFQuery *query = [PFQuery queryWithClassName:self.entity.name];
    [query whereKey:@"docId" equalTo:self.docId];
    [query findObjectsInBackgroundWithBlock:^(NSArray *serverQueryResult, NSError *error) {
        if (error) SKLog(YES, @"Error querying Parse while trying to delete an object: %@", error.description);
        else if (!serverQueryResult.count || serverQueryResult.count > 1) {
            SKLog(YES, @"Error while deleting an object: %d server objects for a doc ID.", serverQueryResult.count);
        }
        else {
            PFObject *serverObject = [serverQueryResult objectAtIndex:0];
            [serverObject setValue:[NSNumber numberWithBool:YES] forKey:SKModelServerKeyDeleted];
            [serverObject saveEventually];
        }
    }];
}


/**
 * Flag this object for push to the server, tagging with the relevant action. If
 * it's already flagged, do the right thing.
 */
- (void)pushToServerWithAction:(NSString *)action
{
    // @todo Think about removing some of the "this shouldn't happen" error code for v1.
    
    if ([action isEqualToString:NSDeletedObjectsKey]) {
        // For simplicity's sake we're pushing deleted objects immediately, so we can avoid
        // tracking a list of deleted objects outside core data. @todo reevaluate at some point.
        // In other words this shouldn't happen.
        SKLog(YES, @"Sync Error: Attempt to queue deletion.");
        
    } else if (!self.serverPushAction || [self.serverPushAction isEqualToString:@""]) {
        // Simplest case. Not currently queued so assign action and we're done.
        self.serverPushAction = action;
        
    } else if ([self.serverPushAction isEqualToString:NSInsertedObjectsKey]) {
        // Already queued for insertion
        if ([action isEqualToString:SKUndeletedObjectsKey]) {
            // This should be impossible. Checking for errors anyway.
            SKLog(YES, @"Error queueing an object for push: Insert + Undelete is theoretically impossible.");
        }
        // Insert + anything else = insert so leave it alone.
        
    } else if ([self.serverPushAction isEqualToString:NSUpdatedObjectsKey]) {
        if ([action isEqualToString:NSInsertedObjectsKey]) {
            SKLog(YES, @"Error queueing an object for push: Update + Insert is theoretically impossible.");
        } else {
            // Use the most recent action in all other cases
            self.serverPushAction = action;
        }
    
    } else if ([self.serverPushAction isEqualToString:NSDeletedObjectsKey]) {
        SKLog(YES, @"Error queuing for push: Delete + anything shouldn't happen.");
        // But just in case...
        self.serverPushAction = action;

    } else if ([self.serverPushAction isEqualToString:SKUndeletedObjectsKey]) {
        if ([action isEqualToString:NSInsertedObjectsKey]) SKLog(YES, @"Error queueing for push: Undelete + Insert shouldn't happen.");
        else if ([action isEqualToString:NSDeletedObjectsKey]) self.serverPushAction = @""; // Undelete + delete gets us back to the server state
        // Otherwise leave it alone.

    } else {
        SKLog(YES, @"Error queuing for push: no queuing clause applied.");
    }
}


/*
 * If the object is queued for server push, unqueue.
 */
- (void)unqueueForServerPush
{
    self.serverPushAction = @"";
}

/**
 * Compare local and remote objects to see which is newer by version, since clocks can't be trusted.
 */
- (NSComparisonResult)compareVersionWithServerObject: (PFObject *)serverObject
{
    int localVersion = [self.docVersion intValue];
    int serverVersion = [[serverObject objectForKey:@"docVersion"] intValue];
    
    if (localVersion == serverVersion) return NSOrderedSame;
    if (localVersion > serverVersion) return NSOrderedDescending;
    return NSOrderedAscending;
}

@end
