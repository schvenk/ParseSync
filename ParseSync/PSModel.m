//
//  PSModel.m
//  ParseSync
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 Dave Feldman. 
//  Licensed under the MIT License (http://www.opensource.org/licenses/mit-license.html).
//

#import "PSModel.h"

@interface PSModel ()
- (void)createDocId;
@end

@implementation PSModel

@dynamic createdAt;
@dynamic updatedAt;
@dynamic docId;

+ (BOOL)shouldIgnoreAttribute:(NSString *)attr pushing:(BOOL)pushing
{
    static NSSet *ignoredAttrsPush;
    static NSSet *ignoredAttrsPull;
    if (!ignoredAttrsPush) ignoredAttrsPush = [NSSet setWithObjects:@"createdAt", @"updatedAt", @"objectId", @"docDeleted", @"needsServerPush", nil];
    if (!ignoredAttrsPull) ignoredAttrsPull = [NSSet setWithObjects:@"objectId", @"docDeleted", @"docOwner", @"needsServerPush", nil];
    
    NSSet *testSet = pushing ? ignoredAttrsPush : ignoredAttrsPull;
    return [testSet containsObject:attr];
}

- (void)awakeFromInsert
{
    [super awakeFromInsert];
    self.createdAt = [NSDate date];
    [self createDocId];
}

- (void)willSave
{
    if (!self.createdAt) [self setPrimitiveValue:[NSDate date] forKey:@"createdAt"]; // @todo For backward compatibility with early alphas
    [self setPrimitiveValue:[NSDate date] forKey:@"updatedAt"];
    [super willSave];
}

- (void)createDocId
{
    self.docId = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, CFUUIDCreate(kCFAllocatorDefault));
}

@end
