/*
 * SPDX-FileCopyrightText: Copyright 2026-Present Todd Schulman
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "DisplayController.h"
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate
    : NSObject <NSApplicationDelegate, DisplayControllerDelegate>
@end

NS_ASSUME_NONNULL_END
