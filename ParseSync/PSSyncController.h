//
//  PSSyncController.h
//  ParseSync
//
//  Created by David Feldman on 3/9/12.
//  Copyright (c) 2012 Dave Feldman. 
//  Licensed under the MIT License (http://www.opensource.org/licenses/mit-license.html).
//

#import <Foundation/Foundation.h>

@interface PSSyncController : NSObject

@property (nonatomic) float syncIntervalInMinutes;

- (id)initWithManagedObjectContext: (NSManagedObjectContext *)context;
- (void)syncEntity: (NSString *)entityName;
- (void)start;

@end
