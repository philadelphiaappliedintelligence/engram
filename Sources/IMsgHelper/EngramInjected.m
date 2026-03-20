//
//  EngramInjected.m
//  Injectable dylib for Messages.app
//
//  Injected via DYLD_INSERT_LIBRARIES to access IMCore's private APIs
//  for typing indicators, read receipts, and tapback reactions.
//  Communicates with Engram via file-based IPC in the Messages.app container.
//
//  Based on imsg-plus (https://github.com/cove-m/imsg-plus)
//  and BlueBubbles IMCore documentation.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

#pragma mark - Constants

static NSString *kCommandFile = nil;
static NSString *kResponseFile = nil;
static NSString *kLockFile = nil;
static NSTimer *fileWatchTimer = nil;

static void initFilePaths(void) {
    if (kCommandFile == nil) {
        NSString *containerPath = NSHomeDirectory();
        kCommandFile = [containerPath stringByAppendingPathComponent:@".engram-imcore-command.json"];
        kResponseFile = [containerPath stringByAppendingPathComponent:@".engram-imcore-response.json"];
        kLockFile = [containerPath stringByAppendingPathComponent:@".engram-imcore-ready"];
    }
}

#pragma mark - Forward Declarations for IMCore Classes

@interface IMChatRegistry : NSObject
+ (instancetype)sharedInstance;
- (id)existingChatWithGUID:(NSString *)guid;
- (id)existingChatWithChatIdentifier:(NSString *)identifier;
- (NSArray *)allExistingChats;
@end

@interface IMChat : NSObject
- (void)setLocalUserIsTyping:(BOOL)typing;
- (void)markAllMessagesAsRead;
- (id)messageForGUID:(NSString *)guid;
- (NSArray *)participants;
- (NSString *)guid;
- (NSString *)chatIdentifier;
@end

@interface IMHandle : NSObject
- (NSString *)ID;
@end

#pragma mark - Compatibility Patches

static BOOL IMMessageItem_isEditedMessageHistory(id self, SEL _cmd) {
    return NO;
}

static void injectCompatibilityMethods(void) {
    SEL selector = @selector(isEditedMessageHistory);
    Class IMMessageItemClass = NSClassFromString(@"IMMessageItem");
    if (IMMessageItemClass && ![IMMessageItemClass instancesRespondToSelector:selector]) {
        class_addMethod(IMMessageItemClass, selector, (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
    }
    Class IMMessageClass = NSClassFromString(@"IMMessage");
    if (IMMessageClass && ![IMMessageClass instancesRespondToSelector:selector]) {
        class_addMethod(IMMessageClass, selector, (IMP)IMMessageItem_isEditedMessageHistory, "c@:");
    }
}

#pragma mark - JSON Helpers

static NSDictionary* successResponse(NSInteger requestId, NSDictionary *data) {
    NSMutableDictionary *response = [NSMutableDictionary dictionaryWithDictionary:data ?: @{}];
    response[@"id"] = @(requestId);
    response[@"success"] = @YES;
    return response;
}

static NSDictionary* errorResponse(NSInteger requestId, NSString *error) {
    return @{@"id": @(requestId), @"success": @NO, @"error": error ?: @"Unknown error"};
}

static void writeResponseToFile(NSDictionary *response) {
    initFilePaths();
    NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    [responseData writeToFile:kResponseFile atomically:YES];
    [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - Chat Resolution

static id findChat(NSString *identifier) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) return nil;

    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) return nil;

    id chat = nil;

    // Try existingChatWithGUID: with common prefixes
    SEL guidSel = @selector(existingChatWithGUID:);
    if ([registry respondsToSelector:guidSel]) {
        if ([identifier containsString:@";"]) {
            chat = [registry performSelector:guidSel withObject:identifier];
            if (chat) return chat;
        }
        NSArray *prefixes = @[@"iMessage;-;", @"iMessage;+;", @"SMS;-;", @"SMS;+;"];
        for (NSString *prefix in prefixes) {
            chat = [registry performSelector:guidSel withObject:[prefix stringByAppendingString:identifier]];
            if (chat) return chat;
        }
    }

    // Try existingChatWithChatIdentifier:
    SEL identSel = @selector(existingChatWithChatIdentifier:);
    if ([registry respondsToSelector:identSel]) {
        chat = [registry performSelector:identSel withObject:identifier];
        if (chat) return chat;
    }

    // Iterate all chats, match by participant
    SEL allChatsSel = @selector(allExistingChats);
    if ([registry respondsToSelector:allChatsSel]) {
        NSArray *allChats = [registry performSelector:allChatsSel];
        if (!allChats) return nil;

        NSMutableString *searchDigits = nil;
        if (identifier.length > 0) {
            searchDigits = [NSMutableString string];
            for (NSUInteger i = 0; i < identifier.length; i++) {
                unichar c = [identifier characterAtIndex:i];
                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                    [searchDigits appendFormat:@"%C", c];
                }
            }
        }

        for (id aChat in allChats) {
            if ([aChat respondsToSelector:@selector(chatIdentifier)]) {
                NSString *chatId = [aChat performSelector:@selector(chatIdentifier)];
                if ([chatId isEqualToString:identifier]) return aChat;
            }
            if ([aChat respondsToSelector:@selector(participants)]) {
                NSArray *participants = [aChat performSelector:@selector(participants)];
                for (id handle in participants) {
                    if ([handle respondsToSelector:@selector(ID)]) {
                        NSString *handleID = [handle performSelector:@selector(ID)];
                        if ([handleID isEqualToString:identifier]) return aChat;
                        if (searchDigits.length >= 10) {
                            NSMutableString *handleDigits = [NSMutableString string];
                            for (NSUInteger i = 0; i < handleID.length; i++) {
                                unichar c = [handleID characterAtIndex:i];
                                if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:c]) {
                                    [handleDigits appendFormat:@"%C", c];
                                }
                            }
                            if (handleDigits.length >= 10 &&
                                ([handleDigits hasSuffix:searchDigits] || [searchDigits hasSuffix:handleDigits])) {
                                return aChat;
                            }
                        }
                    }
                }
            }
        }
    }
    return nil;
}

#pragma mark - Command Handlers

static NSDictionary* handleTyping(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSNumber *state = params[@"typing"] ?: params[@"state"];
    if (!handle) return errorResponse(requestId, @"Missing: handle");

    BOOL typing = [state boolValue];
    id chat = findChat(handle);
    if (!chat) return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);

    @try {
        SEL typingSel = @selector(setLocalUserIsTyping:);
        if ([chat respondsToSelector:typingSel]) {
            NSMethodSignature *sig = [chat methodSignatureForSelector:typingSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:typingSel];
            [inv setTarget:chat];
            [inv setArgument:&typing atIndex:2];
            [inv invoke];
            return successResponse(requestId, @{@"handle": handle, @"typing": @(typing)});
        }
        return errorResponse(requestId, @"setLocalUserIsTyping: not available");
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Typing failed: %@", exception.reason]);
    }
}

static NSDictionary* handleRead(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    if (!handle) return errorResponse(requestId, @"Missing: handle");

    id chat = findChat(handle);
    if (!chat) return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);

    @try {
        SEL readSel = @selector(markAllMessagesAsRead);
        if ([chat respondsToSelector:readSel]) {
            [chat performSelector:readSel];
            return successResponse(requestId, @{@"handle": handle, @"marked_as_read": @YES});
        }
        return errorResponse(requestId, @"markAllMessagesAsRead not available");
    } @catch (NSException *exception) {
        return errorResponse(requestId, [NSString stringWithFormat:@"Read failed: %@", exception.reason]);
    }
}

static NSString* reactionVerb(long long reactionType) {
    long long base = reactionType >= 3000 ? reactionType - 1000 : reactionType;
    switch (base) {
        case 2000: return @"Loved ";
        case 2001: return @"Liked ";
        case 2002: return @"Disliked ";
        case 2003: return @"Laughed at ";
        case 2004: return @"Emphasized ";
        case 2005: return @"Questioned ";
        default:   return @"Reacted to ";
    }
}

static NSDictionary* handleReact(NSInteger requestId, NSDictionary *params) {
    NSString *handle = params[@"handle"];
    NSString *messageGUID = params[@"guid"];
    NSNumber *type = params[@"type"];
    int partIndex = [params[@"partIndex"] intValue];

    if (!handle || !messageGUID || !type)
        return errorResponse(requestId, @"Missing: handle, guid, type");

    id chat = findChat(handle);
    if (!chat) return errorResponse(requestId, [NSString stringWithFormat:@"Chat not found: %@", handle]);

    Class historyClass = NSClassFromString(@"IMChatHistoryController");
    if (!historyClass) return errorResponse(requestId, @"IMChatHistoryController not found");

    id historyController = [historyClass performSelector:@selector(sharedInstance)];
    if (!historyController) return errorResponse(requestId, @"No IMChatHistoryController instance");

    SEL loadSel = @selector(loadMessageWithGUID:completionBlock:);
    if (![historyController respondsToSelector:loadSel])
        return errorResponse(requestId, @"loadMessageWithGUID:completionBlock: not available");

    long long reactionType = [type longLongValue];

    NSMethodSignature *loadSig = [historyController methodSignatureForSelector:loadSel];
    NSInvocation *loadInv = [NSInvocation invocationWithMethodSignature:loadSig];
    [loadInv setSelector:loadSel];
    [loadInv setTarget:historyController];
    [loadInv setArgument:&messageGUID atIndex:2];

    void (^completionBlock)(id) = ^(id message) {
        @autoreleasepool {
            if (!message) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"Message not found: %@", messageGUID]));
                return;
            }
            @try {
                id messageItem = [message valueForKey:@"_imMessageItem"];
                id items = nil;
                if (messageItem && [messageItem respondsToSelector:@selector(_newChatItems)])
                    items = [messageItem performSelector:@selector(_newChatItems)];

                id partItem = nil;
                if ([items isKindOfClass:[NSArray class]]) {
                    NSArray *arr = (NSArray *)items;
                    for (id item in arr) {
                        NSString *cn = NSStringFromClass([item class]);
                        if ([cn containsString:@"MessagePartChatItem"] || [cn containsString:@"TextMessagePartChatItem"]) {
                            if ([item respondsToSelector:@selector(index)]) {
                                NSInteger idx = ((NSInteger (*)(id, SEL))objc_msgSend)(item, @selector(index));
                                if (idx == partIndex) { partItem = item; break; }
                            } else if (partIndex == 0) { partItem = item; break; }
                        }
                    }
                    if (!partItem && arr.count > 0) partItem = arr[partIndex < (int)arr.count ? partIndex : 0];
                } else if (items) {
                    partItem = items;
                }

                NSAttributedString *itemText = nil;
                if (partItem && [partItem respondsToSelector:@selector(text)])
                    itemText = [partItem performSelector:@selector(text)];
                if (!itemText && [message respondsToSelector:@selector(text)])
                    itemText = [message performSelector:@selector(text)];
                NSString *summaryText = itemText ? itemText.string : @"";
                if (!summaryText) summaryText = @"";

                NSString *associatedGuid = [NSString stringWithFormat:@"p:%d/%@", partIndex, messageGUID];
                NSDictionary *messageSummary = @{@"amc": @1, @"ams": summaryText};

                NSString *verb = reactionVerb(reactionType);
                NSMutableAttributedString *reactionText =
                    [[NSMutableAttributedString alloc] initWithString:
                        [verb stringByAppendingString:[NSString stringWithFormat:@"\u201c%@\u201d", summaryText]]];

                NSRange partRange = NSMakeRange(0, summaryText.length);
                if (partItem) {
                    SEL rangeSel = @selector(messagePartRange);
                    if ([partItem respondsToSelector:rangeSel]) {
                        NSMethodSignature *sig = [partItem methodSignatureForSelector:rangeSel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:rangeSel]; [inv setTarget:partItem]; [inv invoke];
                        [inv getReturnValue:&partRange];
                    }
                }

                Class IMMessageClass = NSClassFromString(@"IMMessage");
                if (!IMMessageClass) {
                    writeResponseToFile(errorResponse(requestId, @"IMMessage class not found"));
                    return;
                }

                id reactionMessage = [IMMessageClass alloc];
                SEL initSel = @selector(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:);

                if (![reactionMessage respondsToSelector:initSel]) {
                    writeResponseToFile(errorResponse(requestId, @"IMMessage reaction init not available"));
                    return;
                }

                typedef id (*InitMsgSendType)(id, SEL, id, id, id, id, id, unsigned long long, id, id, id, id, long long, NSRange, id);
                InitMsgSendType initMsgSend = (InitMsgSendType)objc_msgSend;
                reactionMessage = initMsgSend(reactionMessage, initSel,
                    nil, nil, reactionText, nil, nil, 0x5ULL, nil, nil, nil,
                    associatedGuid, reactionType, partRange, messageSummary);

                if (!reactionMessage) {
                    writeResponseToFile(errorResponse(requestId, @"Failed to create reaction message"));
                    return;
                }

                SEL sendSel = @selector(sendMessage:);
                if ([chat respondsToSelector:sendSel]) {
                    [chat performSelector:sendSel withObject:reactionMessage];
                    writeResponseToFile(successResponse(requestId, @{
                        @"handle": handle, @"guid": messageGUID, @"type": type,
                        @"action": reactionType >= 3000 ? @"removed" : @"added"
                    }));
                } else {
                    writeResponseToFile(errorResponse(requestId, @"sendMessage: not available"));
                }
            } @catch (NSException *exception) {
                writeResponseToFile(errorResponse(requestId,
                    [NSString stringWithFormat:@"React failed: %@", exception.reason]));
            }
        }
    };

    [loadInv setArgument:&completionBlock atIndex:3];
    [loadInv invoke];

    // Timeout fallback
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSData *responseData = [NSData dataWithContentsOfFile:kResponseFile];
        if (!responseData || responseData.length < 3) {
            writeResponseToFile(errorResponse(requestId,
                [NSString stringWithFormat:@"Timeout: GUID not found: %@", messageGUID]));
        }
    });

    return nil; // async
}

static NSDictionary* handleStatus(NSInteger requestId, NSDictionary *params) {
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    BOOL hasRegistry = (registryClass != nil);
    NSUInteger chatCount = 0;
    if (hasRegistry) {
        id registry = [registryClass performSelector:@selector(sharedInstance)];
        if ([registry respondsToSelector:@selector(allExistingChats)])
            chatCount = [[registry performSelector:@selector(allExistingChats)] count];
    }
    return successResponse(requestId, @{
        @"injected": @YES, @"registry_available": @(hasRegistry), @"chat_count": @(chatCount),
        @"typing_available": @(hasRegistry), @"read_available": @(hasRegistry), @"tapback_available": @(hasRegistry)
    });
}

static NSDictionary* handlePing(NSInteger requestId, NSDictionary *params) {
    return successResponse(requestId, @{@"pong": @YES});
}

#pragma mark - Command Router

static NSDictionary* processCommand(NSDictionary *command) {
    NSInteger requestId = [command[@"id"] integerValue];
    NSString *action = command[@"action"];
    NSDictionary *params = command[@"params"] ?: @{};

    if ([action isEqualToString:@"typing"]) return handleTyping(requestId, params);
    if ([action isEqualToString:@"read"]) return handleRead(requestId, params);
    if ([action isEqualToString:@"react"]) return handleReact(requestId, params);
    if ([action isEqualToString:@"status"]) return handleStatus(requestId, params);
    if ([action isEqualToString:@"ping"]) return handlePing(requestId, params);
    return errorResponse(requestId, [NSString stringWithFormat:@"Unknown action: %@", action]);
}

#pragma mark - File Watcher

static void processCommandFile(void) {
    initFilePaths();
    NSData *data = [NSData dataWithContentsOfFile:kCommandFile];
    if (!data || data.length < 3) return;

    NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!command) return;

    NSDictionary *response = processCommand(command);
    if (response) {
        writeResponseToFile(response);
    }
    // nil response = async handler will write response later
}

#pragma mark - Entry Point (called on dylib load)

__attribute__((constructor))
static void engram_imcore_init(void) {
    @autoreleasepool {
        NSLog(@"[engram] IMCore helper loaded into Messages.app");
        initFilePaths();
        injectCompatibilityMethods();

        // Clean old IPC files
        [@"" writeToFile:kCommandFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"" writeToFile:kResponseFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // Write ready lock file
        [@"ready" writeToFile:kLockFile atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // Poll command file every 100ms
        dispatch_async(dispatch_get_main_queue(), ^{
            fileWatchTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                repeats:YES block:^(NSTimer *timer) {
                    processCommandFile();
                }];
        });

        NSLog(@"[engram] IMCore helper ready. IPC files at: %@", kCommandFile);
    }
}
