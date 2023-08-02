#import <Foundation/Foundation.h>

#if defined(YAP_FRAMEWORK_PREFIX)
#import <YAP_FRAMEWORK_PREFIX/YapDatabaseExtensionTypes.h>
#import <YAP_FRAMEWORK_PREFIX/YapDatabaseExtensionConnection.h>
#import <YAP_FRAMEWORK_PREFIX/YapDatabaseExtensionTransaction.h>
#else
#import "YapDatabaseExtensionTypes.h"
#import "YapDatabaseExtensionConnection.h"
#import "YapDatabaseExtensionTransaction.h"
#endif

@class YapDatabase;

NS_ASSUME_NONNULL_BEGIN

@interface YapDatabaseExtension : NSObject

/**
 * After an extension has been successfully registered with a database,
 * the registeredName property will be set by the database.
 */
@property (atomic, copy, readonly, nullable) NSString *registeredName;

/**
 * After an extension has been successfully registered with a database,
 * the registeredDatabase property will be set to that database.
 */
@property (atomic, weak, readonly, nullable) YapDatabase *registeredDatabase;

@end

NS_ASSUME_NONNULL_END
