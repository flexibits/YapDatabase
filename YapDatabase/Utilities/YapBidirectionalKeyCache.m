#import "YapBidirectionalKeyCache.h"
#include <corecrt_search.h>
#import "YapDatabaseLogging.h"

static NSUInteger const YapBidirectionalKeyCache_Default_CountLimit = 40;

const YapBidirectionalKeyCacheCallBacks kYapBidirectionalKeyCacheDefaultCallBacks = (YapBidirectionalKeyCacheCallBacks){
	.version = 0,
	.shouldCopy = NO,
	.equal = CFEqual,
	.hash = CFHash
};

static Boolean key_equal(CFTypeRef a, CFTypeRef b)
{
	int64_t keyA = (int64_t)a;
	int64_t keyB = (int64_t)b;

	return keyA == keyB;
}

static CFHashCode key_hash(CFTypeRef a)
{
	int64_t key = (int64_t)a;

	return (CFHashCode)key;
}

static CFStringRef key_copyDescription(CFTypeRef a)
{
	int64_t key = (int64_t)a;

	return CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("%lld"), key);
}

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDBLogLevelOff;
#else
  static const int ydbLogLevel = YDBLogLevelOff;
#endif


@interface YapBidirectionalKeyCacheItem : NSObject {
@public
	
	// Memory Management Architecture:
	//
	// The prev & next pointers are updated regularly, so it's critical that they
	// don't have the overhead of memory management (__strong).
	// The end goal is to have the following retained once, and only once:
	// - key
	// - value
	// - YapBidirectionalKeyCacheItem
	//
	// To achieve this, the key_obj_dict retains the key & YapCacheItem.
	// And the YapBidirectionalKeyCacheItem retains the value.
	
	__unsafe_unretained YapBidirectionalKeyCacheItem *prev;
	__unsafe_unretained YapBidirectionalKeyCacheItem *next;
	
	int64_t key;
	__strong id obj;
}

@end

@implementation YapBidirectionalKeyCacheItem

//- (void)dealloc
//{
//	NSLog(@"[YapBidirectionalKeyCacheItem dealloc]: key: %@, obj: %@", key, obj);
//}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<YapBidirectionalKeyCacheItem: key(%lld) object(%@)>", key, obj];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation YapBidirectionalKeyCache
{
	YapBidirectionalKeyCacheCallBacks objCallBacks;
	
	CFMutableDictionaryRef key_obj_dict;
	CFMutableDictionaryRef obj_key_dict;
	
	__unsafe_unretained YapBidirectionalKeyCacheItem *mostRecentCacheItem;
	__unsafe_unretained YapBidirectionalKeyCacheItem *leastRecentCacheItem;
	
	__strong YapBidirectionalKeyCacheItem *evictedCacheItem;
}

@synthesize countLimit = countLimit;

@synthesize allowedObjectClasses = allowedObjectClasses;

#if YapBidirectionalKeyCache_Enable_Statistics
@synthesize hitCount = hitCount;
@synthesize missCount = missCount;
@synthesize evictionCount = evictionCount;
#endif

- (instancetype)init
{
	return [self initWithCountLimit:YapBidirectionalKeyCache_Default_CountLimit
	                objectCallbacks:NULL];
}

- (instancetype)initWithCountLimit:(NSUInteger)inCountLimit
{
	return [self initWithCountLimit:inCountLimit
	                objectCallbacks:NULL];
}

- (instancetype)initWithCountLimit:(NSUInteger)inCountLimit
                   objectCallbacks:(const YapBidirectionalKeyCacheCallBacks *)inObjCallBacks
{
	if ((self = [super init]))
	{		
		if (inObjCallBacks == NULL)
			inObjCallBacks = &kYapBidirectionalKeyCacheDefaultCallBacks;

		memcpy(&objCallBacks, inObjCallBacks, sizeof(YapBidirectionalKeyCacheCallBacks));
		
		// Setup key_obj_dict.
		// This retains the key & YapBidirectionalItem.
		
		CFDictionaryKeyCallBacks kcb = kCFTypeDictionaryKeyCallBacks;
		kcb.retain = NULL;
		kcb.release = NULL;
		kcb.equal   = key_equal;
		kcb.hash    = key_hash;
		kcb.copyDescription = key_copyDescription;
		
		CFDictionaryValueCallBacks vcb = kCFTypeDictionaryValueCallBacks;
		vcb.equal   = objCallBacks.equal;
		
		key_obj_dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kcb, &vcb);
		
		// Setup obj_key_dict.
		// This does NOT retain its key or value.
		
		kcb.retain  = NULL;
		kcb.release = NULL;
		kcb.equal = objCallBacks.equal;
		kcb.hash  = objCallBacks.hash;
		
		vcb.retain  = NULL;
		vcb.release = NULL;
		vcb.equal = key_equal;
		vcb.copyDescription = key_copyDescription;
		
		obj_key_dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kcb, &vcb);
		
		// zero is a valid countLimit (it means unlimited)
		countLimit = inCountLimit;
	}
	return self;
}

- (void)dealloc
{
	if (key_obj_dict) {
		CFRelease(key_obj_dict);
	}
	if (obj_key_dict) {
		CFRelease(obj_key_dict);
	}
}

- (void)setCountLimit:(NSUInteger)newCountLimit
{
	if (countLimit != newCountLimit)
	{
		countLimit = newCountLimit;
		if (countLimit != 0)
		{
			while (CFDictionaryGetCount(key_obj_dict) > (CFIndex)countLimit)
			{
				int64_t keyToEvict = leastRecentCacheItem->key;
				__unsafe_unretained id objToEvict = leastRecentCacheItem->obj;
				
				if (evictedCacheItem == nil)
				{
					evictedCacheItem = leastRecentCacheItem;
					
					leastRecentCacheItem = leastRecentCacheItem->prev;
					leastRecentCacheItem->next = nil;
					
					CFDictionaryRemoveValue(obj_key_dict, (const void *)(objToEvict)); // must be first
					CFDictionaryRemoveValue(key_obj_dict, (const void *)(keyToEvict)); // must be second
					
					evictedCacheItem->prev = nil;
					evictedCacheItem->next = nil;
					evictedCacheItem->key  = 0;
					evictedCacheItem->obj  = nil; // deallocates obj / objToEvict
				}
				else
				{
					leastRecentCacheItem = leastRecentCacheItem->prev;
					leastRecentCacheItem->next = nil;
					
					CFDictionaryRemoveValue(obj_key_dict, (const void *)(objToEvict)); // must be first
					CFDictionaryRemoveValue(key_obj_dict, (const void *)(keyToEvict)); // must be second
				}
				
			#if YapBidirectionalKeyCache_Enable_Statistics
				evictionCount++;
			#endif
			}
		}
	}
}

- (id)cachedObjectForKey:(int64_t)key
{	
	__unsafe_unretained YapBidirectionalKeyCacheItem *item = CFDictionaryGetValue(key_obj_dict, (const void *)key);
	if (item)
	{
		if (item != mostRecentCacheItem)
		{
			// Remove item from current position in linked-list.
			//
			// Notes:
			// We fetched the item from the list,
			// so we know there's a valid mostRecentCacheItem & leastRecentCacheItem.
			// Furthermore, we know the item isn't the mostRecentCacheItem.
			
			item->prev->next = item->next;
			
			if (item == leastRecentCacheItem)
				leastRecentCacheItem = item->prev;
			else
				item->next->prev = item->prev;
			
			// Move item to beginning of linked-list
			
			item->prev = nil;
			item->next = mostRecentCacheItem;
			
			mostRecentCacheItem->prev = item;
			mostRecentCacheItem = item;
		}
		
	#if YapBidirectionalKeyCache_Enable_Statistics
		hitCount++;
	#endif
		return item->obj;
	}
	else
	{
	#if YapBidirectionalKeyCache_Enable_Statistics
		missCount++;
	#endif
		return nil;
	}
}

- (BOOL)containsCachedKey:(int64_t)key
{	
	return CFDictionaryContainsKey(key_obj_dict, (const void *)key);
}

- (int64_t)cachedKeyForObject:(id)object foundKey:(BOOL *)foundKey
{	
	__unsafe_unretained YapBidirectionalKeyCacheItem *item = CFDictionaryGetValue(obj_key_dict, (const void *)object);
	if (item)
	{
		if (item != mostRecentCacheItem)
		{
			// Remove item from current position in linked-list.
			//
			// Notes:
			// We fetched the item from the list,
			// so we know there's a valid mostRecentCacheItem & leastRecentCacheItem.
			// Furthermore, we know the item isn't the mostRecentCacheItem.
			
			item->prev->next = item->next;
			
			if (item == leastRecentCacheItem)
				leastRecentCacheItem = item->prev;
			else
				item->next->prev = item->prev;
			
			// Move item to beginning of linked-list
			
			item->prev = nil;
			item->next = mostRecentCacheItem;
			
			mostRecentCacheItem->prev = item;
			mostRecentCacheItem = item;
		}
		
	#if YapBidirectionalKeyCache_Enable_Statistics
		hitCount++;
	#endif
		*foundKey = YES;
		return item->key;
	}
	else
	{
	#if YapBidirectionalKeyCache_Enable_Statistics
		missCount++;
	#endif
		*foundKey = NO;
		return 0;
	}
}

- (BOOL)containsCachedObject:(id)object
{
#ifndef NS_BLOCK_ASSERTIONS
	AssertAllowedObjectClass(object, allowedObjectClasses);
#endif
	
	return CFDictionaryContainsKey(obj_key_dict, (const void *)object);
}

- (NSUInteger)count
{
	return CFDictionaryGetCount(key_obj_dict);
}

- (void)setCachedObject:(id)object forKey:(int64_t)key
{
	#ifndef NS_BLOCK_ASSERTIONS
	AssertAllowedObjectClass(object, allowedObjectClasses);
	#endif
	
	__unsafe_unretained YapBidirectionalKeyCacheItem *existingItem = CFDictionaryGetValue(key_obj_dict, (const void *)key);
	if (existingItem)
	{
		// Update item value
		if (!objCallBacks.equal((__bridge const void *)existingItem->obj, (__bridge const void *)object))
		{
			CFDictionaryRemoveValue(obj_key_dict, (const void *)existingItem->obj);
			
			if (objCallBacks.shouldCopy)
				existingItem->obj = [object copy];
			else
				existingItem->obj = object;
			
			CFDictionarySetValue(obj_key_dict, (const void *)existingItem->obj, (const void *)existingItem);
		}
		
		if (existingItem != mostRecentCacheItem)
		{
			// Remove item from current position in linked-list
			//
			// Notes:
			// We fetched the item from the list,
			// so we know there's a valid mostRecentCacheItem & leastRecentCacheItem.
			// Furthermore, we know the item isn't the mostRecentCacheItem.
			
			existingItem->prev->next = existingItem->next;
			
			if (existingItem == leastRecentCacheItem)
				leastRecentCacheItem = existingItem->prev;
			else
				existingItem->next->prev = existingItem->prev;
			
			// Move item to beginning of linked-list
			
			existingItem->prev = nil;
			existingItem->next = mostRecentCacheItem;
			
			mostRecentCacheItem->prev = existingItem;
			mostRecentCacheItem = existingItem;
			
			YDBLogVerbose(@"key(%lld) <- existing, new mostRecent", key);
		}
		else
		{
			YDBLogVerbose(@"key(%lld) <- existing, already mostRecent", key);
		}
	}
	else
	{
		// Create new item (or recycle old evicted item)
		
		__strong YapBidirectionalKeyCacheItem *newItem = nil;
		
		if (evictedCacheItem)
		{
			newItem = evictedCacheItem;
			evictedCacheItem = nil;
		}
		else
		{
			newItem = [[YapBidirectionalKeyCacheItem alloc] init];
		}
		
		int64_t newKey = key;
		
		newItem->key = newKey; // __unsafe_unretained assignment
		
		if (objCallBacks.shouldCopy)
			newItem->obj = [object copy];
		else
			newItem->obj = object;
		
		// Add item to dicts
		
		CFDictionarySetValue(key_obj_dict, (const void *)newKey, (const void *)newItem);
		CFDictionarySetValue(obj_key_dict, (const void *)newItem->obj, (const void *)newItem);
		
		// Add item to beginning of linked-list
		
		newItem->next = mostRecentCacheItem;
		
		if (mostRecentCacheItem)
			mostRecentCacheItem->prev = newItem;
		
		mostRecentCacheItem = newItem;
		
		// Evict leastRecentCacheItem if needed
		
		if ((countLimit != 0) && (CFDictionaryGetCount(key_obj_dict) > (CFIndex)countLimit))
		{
			YDBLogVerbose(@"in(%lld), out(%lld)", key, leastRecentCacheItem->key);
			
			int64_t keyToEvict = leastRecentCacheItem->key;
			__unsafe_unretained id objToEvict = leastRecentCacheItem->obj;
			
			if (evictedCacheItem == nil)
			{
				evictedCacheItem = leastRecentCacheItem;
				
				leastRecentCacheItem = leastRecentCacheItem->prev;
				leastRecentCacheItem->next = nil;
				
				CFDictionaryRemoveValue(obj_key_dict, (const void *)(objToEvict)); // must be first
				CFDictionaryRemoveValue(key_obj_dict, (const void *)(keyToEvict)); // must be second
				
				evictedCacheItem->prev = nil;
				evictedCacheItem->next = nil;
				evictedCacheItem->key  = 0;
				evictedCacheItem->obj  = nil; // deallocates obj / objToEvict
			}
			else
			{
				leastRecentCacheItem = leastRecentCacheItem->prev;
				leastRecentCacheItem->next = nil;
				
				CFDictionaryRemoveValue(obj_key_dict, (const void *)(objToEvict)); // must be first
				CFDictionaryRemoveValue(key_obj_dict, (const void *)(keyToEvict)); // must be second
			}
			
			#if YapBidirectionalKeyCache_Enable_Statistics
			evictionCount++;
			#endif
		}
		else
		{
			if (leastRecentCacheItem == nil)
				leastRecentCacheItem = newItem;
			
			YDBLogVerbose(@"key(%lld) <- new mostRecent [%ld of %lu]",
			              key, (long)CFDictionaryGetCount(key_obj_dict), (unsigned long)countLimit);
		}
	}
	
	if (ydbLogLevel & YDBLogFlagVerbose)
	{
		YDBLogVerbose(@"key_obj_dict: %@", key_obj_dict);
		YDBLogVerbose(@"obj_key_dict: %@", obj_key_dict);
		
		YapBidirectionalKeyCacheItem *loopItem = mostRecentCacheItem;
		NSUInteger i = 0;
		
		while (loopItem != nil)
		{
			YDBLogVerbose(@"%lu: %@", (unsigned long)i, loopItem);
			
			loopItem = loopItem->next;
			i++;
		}
	}
}

- (void)removeAllObjects
{
	leastRecentCacheItem = nil;
	mostRecentCacheItem = nil;
	evictedCacheItem = nil;
	
	CFDictionaryRemoveAllValues(obj_key_dict); // must be first
	CFDictionaryRemoveAllValues(key_obj_dict); // must be second
}

- (void)removeCachedObjectForKey:(int64_t)key
{	
	__unsafe_unretained YapBidirectionalKeyCacheItem *item = CFDictionaryGetValue(key_obj_dict, (const void *)key);
	if (item)
	{
		if (item == mostRecentCacheItem)
			mostRecentCacheItem = item->next;
		else if (item->prev)
			item->prev->next = item->next;
		
		if (item == leastRecentCacheItem)
			leastRecentCacheItem = item->prev;
		else if (item->next)
			item->next->prev = item->prev;
		
		CFDictionaryRemoveValue(obj_key_dict, (const void *)item->obj); // must be first
		CFDictionaryRemoveValue(key_obj_dict, (const void *)item->key); // must be second
	}
}

- (void)removeObjectsForKeys:(id <NSFastEnumeration>)keys
{
	for (NSNumber *key in keys)
	{
		int64_t keyValue = [key longLongValue];
		__unsafe_unretained YapBidirectionalKeyCacheItem *item = CFDictionaryGetValue(key_obj_dict, (const void *)keyValue);

		if (item)
		{
			if (item == mostRecentCacheItem)
				mostRecentCacheItem = item->next;
			else if (item->prev)
				item->prev->next = item->next;
			
			if (item == leastRecentCacheItem)
				leastRecentCacheItem = item->prev;
			else if (item->next)
				item->next->prev = item->prev;
			
			CFDictionaryRemoveValue(obj_key_dict, (const void *)item->obj); // must be first
			CFDictionaryRemoveValue(key_obj_dict, (const void *)item->key); // must be second
		}
	}
}

- (void)removeKeyForObject:(id)object
{
	#ifndef NS_BLOCK_ASSERTIONS
	AssertAllowedObjectClass(object, allowedObjectClasses);
	#endif
	
	__unsafe_unretained YapBidirectionalKeyCacheItem *item = CFDictionaryGetValue(obj_key_dict, (const void *)object);
	if (item)
	{
		if (item == mostRecentCacheItem)
			mostRecentCacheItem = item->next;
		else if (item->prev)
			item->prev->next = item->next;
		
		if (item == leastRecentCacheItem)
			leastRecentCacheItem = item->prev;
		else if (item->next)
			item->next->prev = item->prev;
		
		CFDictionaryRemoveValue(obj_key_dict, (const void *)item->obj); // must be first
		CFDictionaryRemoveValue(key_obj_dict, (const void *)item->key); // must be second
	}
}

- (void)removeKeysForObjects:(id <NSFastEnumeration>)objects
{
	for (id object in objects)
	{
		#ifndef NS_BLOCK_ASSERTIONS
		AssertAllowedObjectClass(object, allowedObjectClasses);
		#endif
		
		__unsafe_unretained YapBidirectionalKeyCacheItem *item = CFDictionaryGetValue(obj_key_dict, (const void *)object);
		if (item)
		{
			if (item == mostRecentCacheItem)
				mostRecentCacheItem = item->next;
			else if (item->prev)
				item->prev->next = item->next;
			
			if (item == leastRecentCacheItem)
				leastRecentCacheItem = item->prev;
			else if (item->next)
				item->next->prev = item->prev;
			
			CFDictionaryRemoveValue(obj_key_dict, (const void *)item->obj); // must be first
			CFDictionaryRemoveValue(key_obj_dict, (const void *)item->key); // must be second
		}
	}
}

- (void)enumerateCachedKeysWithBlock:(void (NS_NOESCAPE^)(int64_t key, BOOL *stop))block
{
	// We could simply walk the linked-list starting with mostRecentCacheItem,
	// but that breaks the API contract in certain cases.
	//
	// 1. The user wouldn't expect that reading from the cache during enumeration would mutate the cache.
	//    But it would change the linked-list order, and would break the in-progress enumeration.
	//
	// 2. We still need to detect and throw "modified during enumeration" exceptions.
	//    We get this for free if we use the underlying dictionary for enumeration.
	CFIndex count = CFDictionaryGetCount(key_obj_dict);
	NSMutableData *nsMutableData;
	int64_t stackAlloc[16];
	int64_t *keys;

	if (count <= 16) {
		keys = stackAlloc;
	} else {
		nsMutableData = [[NSMutableData alloc] initWithLength:count * sizeof(int64_t)];
		keys = (int64_t *)[nsMutableData bytes];
	}

	CFDictionaryGetKeysAndValues(key_obj_dict, (const void **)&keys, NULL);

	BOOL stop = NO;
	
	for (int i = 0; !stop && i < count; ++i)
	{
		block(keys[i], &stop);
	}
}

- (void)enumerateObjectsWithBlock:(void (NS_NOESCAPE^)(id object, BOOL *stop))block
{
	// We could simply walk the linked-list starting with mostRecentCacheItem,
	// but that breaks the API contract in certain cases.
	//
	// 1. The user wouldn't expect that reading from the cache during enumeration would mutate the cache.
	//    But it would change the linked-list order, and would break the in-progress enumeration.
	//
	// 2. We still need to detect and throw "modified during enumeration" exceptions.
	//    We get this for free if we use the underlying dictionary for enumeration.
	
	NSDictionary *nsdict = (__bridge NSDictionary *)obj_key_dict;
	BOOL stop = NO;
	
	for (id obj in [nsdict keyEnumerator])
	{
		block(obj, &stop);
		
		if (stop) break;
	}
}

- (void)enumerateCachedKeysAndObjectsWithBlock:(void (NS_NOESCAPE^)(int64_t key, id obj, BOOL *stop))block
{
	// We could simply walk the linked-list starting with mostRecentCacheItem,
	// but that breaks the API contract in certain cases.
	//
	// 1. The user wouldn't expect that reading from the cache during enumeration would mutate the cache.
	//    But it would change the linked-list order, and would break the in-progress enumeration.
	//
	// 2. We still need to detect and throw "modified during enumeration" exceptions.
	//    We get this for free if we use the underlying dictionary for enumeration.
	
	NSDictionary *nsdict = (__bridge NSDictionary *)obj_key_dict;
	
	[nsdict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		__unsafe_unretained YapBidirectionalKeyCacheItem *cacheItem = (YapBidirectionalKeyCacheItem *)obj;
		
		block(cacheItem->key, key, stop);
	}];
}

#ifndef NS_BLOCK_ASSERTIONS
static void AssertAllowedKeyClass(id key, NSSet *allowedKeyClasses)
{
	if (allowedKeyClasses == nil) return;

//	This doesn't work.
//	For example, @(number) gives us class '__NSCFNumber', which is not NSNumber.
//	And there are also class clusters which break this technique too.
//
//	return [allowedKeyClasses containsObject:[key class]];
	
	// So we have to use the isKindOfClass method,
	// which means we need to enumerate the allowedKeyClasses.
	
	for (Class allowedKeyClass in allowedKeyClasses)
	{
		if ([key isKindOfClass:allowedKeyClass]) return;
	}
	
	NSCAssert(NO, @"Unexpected key class. Passed %@, expected: %@", [key class], allowedKeyClasses);
}
#endif

#ifndef NS_BLOCK_ASSERTIONS
static void AssertAllowedObjectClass(id obj, NSSet *allowedObjectClasses)
{
	if (allowedObjectClasses == nil) return;
	
//	This doesn't work.
//	For example, @(number) gives us class '__NSCFNumber', which is not NSNumber.
//	And there are also class clusters which break this technique too.
//
//	return [allowedObjectClasses containsObject:[obj class]];
	
	// So we have to use the isKindOfClass method,
	// which means we need to enumerate the allowedKeyClasses.
	
	for (Class allowedObjectClass in allowedObjectClasses)
	{
		if ([obj isKindOfClass:allowedObjectClass]) return;
	}
	
	NSCAssert(NO, @"Unexpected object class. Passed %@, expected: %@", [obj class], allowedObjectClasses);
}
#endif

@end
