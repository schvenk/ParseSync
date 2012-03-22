//
//  PSModel.h
//  ParseSync
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 Dave Feldman. 
//  Licensed under the MIT License (http://www.opensource.org/licenses/mit-license.html).
//

#import <CoreData/CoreData.h>
#import <Parse/Parse.h>

#define SKModelServerKeyDeleted @"docDeleted"

@interface PSModel : NSManagedObject

@property (nonatomic, retain) NSDate * createdAt;
@property (nonatomic, retain) NSDate * updatedAt;
@property (nonatomic, retain) NSString * docId;

+ (BOOL)shouldIgnoreAttribute:(NSString *)attr pushing:(BOOL)pushing;

@end
