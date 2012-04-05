//
//  SKSyncController.h
//  stky
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface PSSyncController : NSObject

@property (nonatomic) float pushIntervalInMinutes;
@property (nonatomic) float pullIntervalInMinutes;

- (id)initWithManagedObjectContext: (NSManagedObjectContext *)context;
- (id)init; // Initialize with managed object context using Apple's conventions

- (void)addEntity:(NSString *)entityName; // Add core data entity by name for syncing with Parse
- (void)start; // Actually begin syncing. Nothing really happens before this is called.

@end
