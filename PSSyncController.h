//
//  SKSyncController.h
//  stky
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>

#define PSNotificationLocalObjectsUpdatedFromServer @"PSNotificationLocalObjectsUpdatedFromServer"

@interface PSSyncController : NSObject

@property (nonatomic) float pushIntervalInMinutes;
@property (nonatomic) float pullIntervalInMinutes;
@property (nonatomic, strong) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, readonly) BOOL isSavingSyncedChanges;

+ (PSSyncController *)sharedInstance;

- (void)addEntity:(NSString *)entityName; // Add core data entity by name for syncing with Parse
- (void)start; // Actually begin syncing. Nothing really happens before this is called.
- (void)stop;

@end
