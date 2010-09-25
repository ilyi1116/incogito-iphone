//
//  javazoneSessionsRetriever.m
//
//  Copyright 2010 Chris Searle. All rights reserved.
//

#import "JavazoneSessionsRetriever.h"
#import "SessionDownloader.h"
#import "SessionParser.h"

#import "JZSession.h"
#import "JZSessionBio.h"
#import "JZLabel.h"
#import "FlurryAPI.h"

@implementation JavazoneSessionsRetriever

@synthesize managedObjectContext;
@synthesize refreshCommonViewController;
@synthesize labelUrls;
@synthesize levelUrls;

@synthesize levelsPath;
@synthesize labelsPath;

-(id) init {
    self = [super init];

	NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
	
	self.levelsPath = [docDir stringByAppendingPathComponent:@"levelIcons"];
	self.labelsPath = [docDir stringByAppendingPathComponent:@"labelIcons"];

	self.labelUrls = [[NSMutableDictionary alloc] init];
	self.levelUrls = [[NSMutableDictionary alloc] init];
	
	return self;
}

-(void)clearPath:(NSString *)path {
	NSFileManager *fileManager = [NSFileManager defaultManager];

	NSError *error = nil;

	[fileManager removeItemAtPath:path error:&error];
	if (nil != error) {
		[FlurryAPI logError:@"Error removing path" message:[NSString stringWithFormat:@"Unable to remove items at path %@", path] error:error];
		return;
	}

	[fileManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
	if (nil != error) {
		[FlurryAPI logError:@"Error creating path" message:[NSString stringWithFormat:@"Unable to create path %@", path] error:error];
		return;
	}
}

- (void)clearData {
	[FlurryAPI logEvent:@"Clearing" timed:YES];
	
	// Set all sessions inactive. Active flag will be set for existing and new sessions retrieved.
	[self invalidateSessions];
	
	// Remove any downloaded icons
	[self clearPath:self.levelsPath];
	[self clearPath:self.labelsPath];
	
	// Remove speakers - they will get added for all active sessions.
	[self removeAllEntitiesByName:@"JZSessionBio"];
	
	// Remove labels - they will get added for all active sessions.
	[self removeAllEntitiesByName:@"JZLabel"];
	
	
	[FlurryAPI endTimedEvent:@"Clearing" withParameters:nil];
}

- (NSUInteger)retrieveSessions:(NSString *)urlString {
	// Download
	SessionDownloader *downloader = [[[SessionDownloader alloc] initWithUrl:[NSURL URLWithString:urlString]] retain];
	
	NSData *responseData = [downloader sessionData];
	
	[downloader release];
	
	if (responseData == nil) {
		return 0;
	}
	
	[refreshCommonViewController performSelectorOnMainThread:@selector(showProgressBar:) withObject:nil waitUntilDone:YES];
	
	// Parse
	SessionParser *parser = [[[SessionParser alloc] initWithData:responseData] retain];
	
	NSArray *sessions = [parser sessions];
	
	[parser release];

	if (sessions == nil) {
		return 0;
	}
	
	// Cleanup
	[self clearData];

	// Store
	[FlurryAPI logEvent:@"Storing" timed:YES];

	int counter = 0;
	
	for (NSDictionary *session in sessions)
	{
		counter++;
		
		float progress = (1.0 / [sessions count]) * counter;
		
		[refreshCommonViewController performSelectorOnMainThread:@selector(setProgressTo:) withObject:[NSNumber numberWithFloat:progress] waitUntilDone:YES];
		
		[self addSession:session];
	}
	
	for (NSString *name in self.levelUrls) {
		[self downloadIconFromUrl:[self.levelUrls objectForKey:name] withName:name toFolder:self.levelsPath];
	}
	for (NSString *name in self.labelUrls) {
		[self downloadIconFromUrl:[self.labelUrls objectForKey:name] withName:name toFolder:self.labelsPath];
	}
	
	[self.labelUrls release];
	[self.levelUrls release];
	
	[FlurryAPI endTimedEvent:@"Storing" withParameters:nil];

	return [sessions count];
}

- (void) invalidateSessions {
	NSEntityDescription *entityDescription = [NSEntityDescription
											  entityForName:@"JZSession" inManagedObjectContext:managedObjectContext];
	
	NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
	[request setEntity:entityDescription];
	
	NSError *error = nil;
	
	NSArray *array = [managedObjectContext executeFetchRequest:request error:&error];
	
	if (nil != error) {
		[FlurryAPI logError:@"Error fetching sessions" message:@"Unable to fetch sessions for invalidation" error:error];
		return;
	}
	
	
	for (JZSession *session in array) {
		[session setActive:[NSNumber numberWithBool:FALSE]];
	}
	
	error = nil;
	
	if (![managedObjectContext save:&error]) {
		if (nil != error) {
			[FlurryAPI logError:@"Error fetching sessions" message:@"Unable to persist sessions after invalidation" error:error];
			NSLog(@"%@:%@ Error saving sessions: %@", [self class], _cmd, [error localizedDescription]);
			return;
		}
	}	
}

- (void) addSession:(NSDictionary *)item {
	NSEntityDescription *entityDescription = [NSEntityDescription
											  entityForName:@"JZSession" inManagedObjectContext:managedObjectContext];
	
	NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
	[request setEntity:entityDescription];
	
	NSPredicate *predicate = [NSPredicate predicateWithFormat:
							  @"(jzId like[cd] %@)", [item objectForKey:@"id"]];
	
	[request setPredicate:predicate];
	
	NSError *error = nil;
	
	NSArray *sessions = [managedObjectContext executeFetchRequest:request error:&error];
	
	if (nil != error) {
		NSLog(@"%@:%@ Error fetching sessions: %@", [self class], _cmd, [error localizedDescription]);
		return;
	}
	
	JZSession *session;
	
	if (sessions == nil)
	{
		// Create and configure a new instance of the Event entity
		session = (JZSession *)[NSEntityDescription insertNewObjectForEntityForName:@"JZSession" inManagedObjectContext:managedObjectContext];
	} else {
		int count = [sessions count];
		
		if (count == 0) {
			session = (JZSession *)[NSEntityDescription insertNewObjectForEntityForName:@"JZSession" inManagedObjectContext:managedObjectContext];
		} else {
			session = (JZSession *)[sessions objectAtIndex:0];
		}
	}
	
#ifdef LOG_FUNCTION_TIMES
	NSLog(@"%@ Adding session with title %@", [[[NSDate alloc] init] autorelease], [item objectForKey:@"title"]);
#endif
	
	[session setJzId:[item objectForKey:@"id"]];
	[session setActive:[NSNumber numberWithBool:TRUE]];
	
	[session setTitle:[self getPossibleNilString:@"title" fromDict:item]];
	
	NSString *roomString = [self getPossibleNilString:@"room" fromDict:item];
	
	if (roomString == @"") {
		[session setRoom:0];
	} else {
		[session setRoom:[NSNumber numberWithInt:[[roomString
												   stringByReplacingOccurrencesOfString:@"Sal " withString:@""] intValue]]];
	}
	
	NSDictionary *level = [item objectForKey:@"level"];
	
	[session setLevel:[level objectForKey:@"id"]];
	[levelUrls setObject:[self getPossibleNilString:@"iconUrl" fromDict:level] forKey:[session level]];

	[session setDetail:[self getPossibleNilString:@"bodyHtml" fromDict:item]];
	
	// Dates
	NSObject *start = [item objectForKey:@"start"];
	if ([start class] != [NSNull class]) {
		NSDictionary *start = [item objectForKey:@"start"];
		[session setStartDate:[self getDateFromJson:start]];
	}
	
	NSObject *end = [item objectForKey:@"end"];
	if ([end class] != [NSNull class]) {
		NSDictionary *end = [item objectForKey:@"end"];
		[session setEndDate:[self getDateFromJson:end]];
	}
	
	NSArray *speakers = [item objectForKey:@"speakers"];
	
	for (NSDictionary *speaker in speakers) {
		JZSessionBio *sessionBio = (JZSessionBio *)[NSEntityDescription insertNewObjectForEntityForName:@"JZSessionBio" inManagedObjectContext:managedObjectContext];
		
		[sessionBio setBio:[self getPossibleNilString:@"bioHtml" fromDict:speaker]];
		[sessionBio setName:[self getPossibleNilString:@"name" fromDict:speaker]];
		
		[session addSpeakersObject:sessionBio];
	}
	
	NSArray *labels = [item objectForKey:@"labels"];
	
	for (NSDictionary *label in labels) {
		JZLabel *lbl = (JZLabel *)[NSEntityDescription insertNewObjectForEntityForName:@"JZLabel" inManagedObjectContext:managedObjectContext];
		
		[lbl setJzId:[label objectForKey:@"id"]];
		
		[lbl setTitle:[self getPossibleNilString:@"displayName" fromDict:label]];
		
		[labelUrls setObject:[self getPossibleNilString:@"iconUrl" fromDict:label] forKey:[lbl jzId]];
		
		[session addLabelsObject:lbl];
	}
	
#ifdef USE_DUMMY_LABELS
	
	if ([speakers count] % 2 == 0) {
		JZLabel *lbl = (JZLabel *)[NSEntityDescription insertNewObjectForEntityForName:@"JZLabel" inManagedObjectContext:managedObjectContext];
		
		[lbl setJzId:@"enterprise"];
		[lbl setTitle:@"Enterprise"];
		
		[session addLabelsObject:lbl];
	} else {
		JZLabel *lbl = (JZLabel *)[NSEntityDescription insertNewObjectForEntityForName:@"JZLabel" inManagedObjectContext:managedObjectContext];
		
		[lbl setJzId:@"core-jvm"];
		[lbl setTitle:@"Core/JVM"];
		
		[session addLabelsObject:lbl];
	}
	
	if ([[item objectForKey:@"title"] hasPrefix:@"H"]) {
		JZLabel *lbl = (JZLabel *)[NSEntityDescription insertNewObjectForEntityForName:@"JZLabel" inManagedObjectContext:managedObjectContext];
		
		[lbl setJzId:@"tooling"];
		[lbl setTitle:@"Tooling"];
		
		[session addLabelsObject:lbl];
	}
	
#endif
	
	error = nil;
	
	if (![managedObjectContext save:&error]) {
		if (nil != error) {
			NSLog(@"%@:%@ Error saving sessions: %@", [self class], _cmd, [error localizedDescription]);
			return;
		}
	}
}

- (NSDate *)getDateFromJson:(NSDictionary *)jsonDate {
	NSString *dateString = [NSString stringWithFormat:@"%@-%@-%@ %@:%@:00 +0200",
							[jsonDate objectForKey:@"year"],
							[jsonDate objectForKey:@"month"],
							[jsonDate objectForKey:@"day"],
							[jsonDate objectForKey:@"hour"],
							[jsonDate objectForKey:@"minute"]];
	
	NSDate *date = [[[NSDate alloc] initWithString:dateString] autorelease];
	
	return date;
}

- (void) removeAllEntitiesByName:(NSString *)entityName {
#ifdef LOG_FUNCTION_TIMES
	NSLog(@"%@ Removing all %@", [[[NSDate alloc] init] autorelease], entityName);
#endif
	
	NSEntityDescription *entityDescription = [NSEntityDescription
											  entityForName:entityName inManagedObjectContext:managedObjectContext];
	
	NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
	[request setEntity:entityDescription];
	
	NSError *error = nil;
	
	NSArray *array = [managedObjectContext executeFetchRequest:request error:&error];
	
	for (NSManagedObject *item in array) {
		[managedObjectContext deleteObject:item];
	}
	
	if (![managedObjectContext save:&error]) {
		if (nil != error) {
			NSLog(@"%@:%@ Error saving sessions: %@", [self class], _cmd, [error localizedDescription]);
			return;
		}
	}	
	
#ifdef LOG_FUNCTION_TIMES
	NSLog(@"%@ Removed all %@", [[[NSDate alloc] init] autorelease], entityName);
#endif
}

- (NSString *)getPossibleNilString:(NSString *)key fromDict:(NSDictionary *)dict {
	NSString *value = [dict objectForKey:key];
	
	if ([value isKindOfClass:[NSNull class]]) {
		NSString *id = [dict objectForKey:@"id"];
		
		if ([id isKindOfClass:[NSNull class]]) {
			NSLog(@"No %@ found for unknown object", key);
		} else {
			NSLog(@"No %@ found for %@", key, id);
		}
		
		return @"";
	}
	
	return value;
}

- (void)downloadIconFromUrl:(NSString *)url withName:(NSString *)name toFolder:(NSString *)folder {
	UIApplication* app = [UIApplication sharedApplication];

	NSLog(@"Download %@ from %@ to %@", name, url, folder);

	app.networkActivityIndicatorVisible = YES;
	UIImage *image = [[UIImage alloc] initWithData:[NSData dataWithContentsOfURL:[NSURL URLWithString:url]]];
	app.networkActivityIndicatorVisible = NO;
	
	NSString *pngFilePath = [NSString stringWithFormat:@"%@/%@.png",folder,name];
	NSData *data1 = [NSData dataWithData:UIImagePNGRepresentation(image)];
	[data1 writeToFile:pngFilePath atomically:YES];
	
	[image release];
}



@end
