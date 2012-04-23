//
//  SKModel.h
//  stky
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 __MyCompanyName__. All rights reserved.
//

#import <CoreData/CoreData.h>
#import <Parse/Parse.h>

#define SKUndeletedObjectsKey @"SKUndeletedObjectsKey"
#define SKModelServerKeyDeleted @"docDeleted"

@interface PSModel : NSManagedObject

@property (nonatomic, retain) NSDate * createdAt;
@property (nonatomic, retain) NSDate * updatedAt;
@property (nonatomic, retain) NSString * docId;
@property (nonatomic, retain) NSNumber * docVersion;
@property (nonatomic, retain) NSString *serverPushAction;

+ (BOOL)shouldIgnoreAttribute:(NSString *)attr pushing:(BOOL)pushing;

- (void)pushToServerWithAction:(NSString *)action;
- (void)deleteOnServer;
- (void)unqueueForServerPush;
- (NSComparisonResult)compareVersionWithServerObject: (PFObject *)serverObject;

@end
