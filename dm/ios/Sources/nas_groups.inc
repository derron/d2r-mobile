// 包含于 DMNASStore 内：格式 4 独立保存原始文件分组。
// Included inside DMNASStore: format 4 stores independent raw-file groups.
- (BOOL)validGroups:(NSDictionary *)m error:(NSError **)e {
    if (!uuid(m[@"id"]) || ![m[@"groups"] isKindOfClass:NSDictionary.class] || [m[@"groups"] count] > kFiles) return DMNASIssue(e, DMNASDataError, "GroupsInvalid", 0);
    for (NSString *slot in @[@"current", @"backup"]) {
        NSMutableArray *all = [NSMutableArray array];
        for (NSString *key in m[@"groups"]) {
            id g = m[@"groups"][key];
            if (![g isKindOfClass:NSDictionary.class] || !str(g[@"kind"]) || !str(g[@"name"]) || !str(g[@"root"])) return DMNASIssue(e, DMNASDataError, "GroupOwnerInvalid", 0);
            NSString *kind = g[@"kind"], *expected = [kind isEqual:@"auxiliary"] ? @"auxiliary" : [NSString stringWithFormat:@"%@:%@", kind, g[@"name"]];
            if (![@[@"character", @"stash", @"auxiliary"] containsObject:kind] || ![expected isEqual:key] || (![kind isEqual:@"auxiliary"] && (!DMNASValidPath(g[@"name"]) || [g[@"name"] containsString:@"/"] || !([g[@"root"] isEqual:g[@"name"]] || [g[@"root"] isEqual:[g[@"name"] stringByAppendingString:@"/"]])))) return DMNASIssue(e, DMNASDataError, "GroupIDInvalid", 0);
            id v = g[slot]; if (v == NSNull.null && [slot isEqual:@"backup"]) continue;
            if (!validManifest(v, e)) return NO;
            [all addObjectsFromArray:v[@"files"]];
            NSDictionary *split = DMNASGroups(v, m[@"groups"], e); if (!split) return NO;
            for (NSString *owner in split) if (![owner isEqual:key]) return DMNASIssue(e, DMNASDataError, "GroupFilesConflict", 0);
        }
        [all sortUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch]; }];
        if (!validManifest(@{@"format":@2, @"id":m[@"id"], @"parent":@"", @"device":self.device, @"savedAt":@0, @"files":all}, e)) return NO;
    }
    return YES;
}
- (NSDictionary *)emptyGroup:(NSDictionary *)g stamp:(double)stamp {
    return @{@"format":@1, @"id":NSUUID.UUID.UUIDString, @"parent":@"", @"device":self.device, @"savedAt":@(stamp), @"files":@[], @"digest":digest(@[])};
}
- (NSDictionary *)aggregate:(NSDictionary *)meta slot:(NSString *)slot {
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *g in [meta[@"groups"] allValues]) if ([g[slot] isKindOfClass:NSDictionary.class]) [files addObjectsFromArray:g[slot][@"files"]];
    [files sortUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch]; }];
    NSMutableDictionary *m = [@{@"format":@1, @"id":meta[@"id"], @"parent":@"", @"device":self.device, @"savedAt":@0, @"files":files} mutableCopy];
    BOOL hashed = YES; for (NSDictionary *f in files) if (!hex(f[@"sha256"]) || !number(f[@"size"])) hashed = NO;
    if (hashed) m[@"digest"] = digest(files);
    return m;
}
- (NSDictionary *)knownGroups {
    id groups = readJSON([self path:@"group-owners.json"]);
    return [groups isKindOfClass:NSDictionary.class] ? groups : @{};
}
- (BOOL)rememberGroups:(NSDictionary *)meta error:(NSError **)e {
    NSMutableDictionary *owners = [NSMutableDictionary dictionary];
    for (NSString *key in meta[@"groups"]) { NSDictionary *g = meta[@"groups"][key]; owners[key] = @{@"kind":g[@"kind"], @"name":g[@"name"], @"root":g[@"root"]}; }
    return putJSON(owners, [self path:@"group-owners.json"], e);
}
// 直接导入手工放入的原始文件，不读取或转换其他协议布局。
// Import manually supplied raw files directly, without reading other protocol layouts.
- (NSDictionary *)initializeGroups:(NSDictionary *)snapshot backup:(NSDictionary *)previous error:(NSError **)e {
    NSDictionary *current = DMNASGroups(snapshot, @{}, e); if (!current) return nil;
    NSDictionary *backup = previous ? DMNASGroups(previous, current, e) : @{}; if (!backup) return nil;
    NSMutableSet *keys = [NSMutableSet setWithArray:current.allKeys]; [keys addObjectsFromArray:backup.allKeys];
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        NSDictionary *g = current[key] ?: backup[key];
        groups[key] = @{@"kind":g[@"kind"], @"name":g[@"name"], @"root":g[@"root"], @"current":current[key] ?: [self emptyGroup:g stamp:0], @"backup":backup[key] ?: NSNull.null};
    }
    NSDictionary *meta = @{@"format":@4, @"id":snapshot[@"id"], @"groups":groups};
    if (![self validGroups:meta error:e] || ![self writeJSON:meta path:metadataPath error:e] || ![self rememberGroups:meta error:e]) return nil;
    return meta;
}
- (NSDictionary *)groupMetadata:(BOOL *)missing error:(NSError **)e {
    NSDictionary *stored = [self storedMetadata:missing error:e]; if (!stored) return nil;
    NSMutableDictionary *meta = [stored mutableCopy];
    id observed = readJSON([self path:@"groups-observed.json"]); if (![observed isKindOfClass:NSDictionary.class]) observed = @{};
    id state = readJSON([self path:@"state.json"]); if (![state isKindOfClass:NSDictionary.class]) state = @{};
    self.activityGroups = meta[@"groups"];
    NSDictionary *actual = [self adopt:@"save/" version:meta[@"id"] force:self.refreshCurrentFiles error:e]; if (!actual) return nil;
    NSDictionary *split = DMNASGroups(actual, meta[@"groups"], e); if (!split) return nil;
    NSMutableDictionary *groups = [meta[@"groups"] mutableCopy], *newObserved = [NSMutableDictionary dictionary];
    NSMutableSet *keys = [NSMutableSet setWithArray:groups.allKeys]; [keys addObjectsFromArray:split.allKeys]; BOOL changed = NO;
    for (NSString *key in keys) {
        NSDictionary *g = groups[key], *prior = g[@"current"], *fresh = split[key] ?: [self emptyGroup:g stamp:[actual[@"savedAt"] doubleValue]];
        // hash 仅用于本机观察；远端字段不作为下载校验条件。
        // Hashes are local observations only. Remote fields never gate a download.
        NSDictionary *base = [observed[key][@"id"] isEqual:prior[@"id"]] ? observed[key] : nil;
        NSString *baseline = base[@"digest"];
        if (!baseline && [state[@"groups"][key][@"revision"] isEqual:prior[@"id"]]) baseline = state[@"groups"][key][@"digest"];
        BOOL edited = !prior || ![[prior[@"files"] valueForKey:@"path"] isEqual:[fresh[@"files"] valueForKey:@"path"]] || (baseline && ![baseline isEqual:fresh[@"digest"]]);
        NSMutableDictionary *version = [(edited ? fresh : prior) mutableCopy];
        version[@"files"] = fresh[@"files"]; version[@"digest"] = fresh[@"digest"];
        if (edited) { version[@"parent"] = prior[@"id"] ?: @""; version[@"savedAt"] = @(NSDate.date.timeIntervalSince1970); version[@"external"] = @YES; changed = YES; }
        else {
            NSMutableArray *files = [NSMutableArray array];
            for (NSUInteger i = 0; i < [fresh[@"files"] count]; i++) { NSMutableDictionary *f = [fresh[@"files"][i] mutableCopy]; f[@"mtime"] = prior[@"files"][i][@"mtime"]; [files addObject:f]; }
            version[@"files"] = files;
        }
        NSDictionary *descriptor = g ?: fresh;
        groups[key] = @{@"kind":descriptor[@"kind"], @"name":descriptor[@"name"], @"root":descriptor[@"root"], @"current":version, @"backup":g[@"backup"] ?: NSNull.null};
        newObserved[key] = @{@"id":version[@"id"], @"digest":version[@"digest"]};
    }
    meta[@"groups"] = groups; if (changed) meta[@"id"] = NSUUID.UUID.UUIDString;
    if (![self validGroups:meta error:e] || (changed && ![self writeJSON:meta path:metadataPath error:e])) return nil;
    if (![self rememberCurrent:[self aggregate:meta slot:@"current"] listing:self.currentListing error:e] || !putJSON(newObserved, [self path:@"groups-observed.json"], e)) return nil;
    return meta;
}
- (BOOL)parents:(NSString *)path created:(NSMutableSet *)created error:(NSError **)e {
    NSString *parent = path.stringByDeletingLastPathComponent, *dir = @"";
    for (NSString *part in parent.pathComponents) {
        dir = [dir stringByAppendingFormat:@"%@/", part];
        if (![created containsObject:dir]) { if (![self mkdir:dir error:e]) return NO; [created addObject:dir]; }
    }
    return YES;
}
- (NSArray *)groupSteps:(NSDictionary *)meta key:(NSString *)key old:(NSDictionary *)old {
    NSMutableArray *steps = [NSMutableArray array];
    id backup = old[@"backup"];
    if ([backup isKindOfClass:NSDictionary.class]) for (NSDictionary *f in backup[@"files"]) [steps addObject:@{@"delete":[@"backup/" stringByAppendingString:escaped(f[@"path"])]}];
    for (NSDictionary *f in old[@"current"][@"files"]) [steps addObject:@{@"from":[@"save/" stringByAppendingString:escaped(f[@"path"])], @"to":[@"backup/" stringByAppendingString:escaped(f[@"path"])]}];
    for (NSDictionary *f in meta[@"groups"][key][@"current"][@"files"]) [steps addObject:@{@"from":[uploadPath stringByAppendingString:escaped(f[@"path"])], @"to":[@"save/" stringByAppendingString:escaped(f[@"path"])]}];
    return steps;
}
// 只对独占、非空角色目录采用整目录事务；平铺存档与仓库沿用逐文件事务。
// Whole-directory transactions apply only to exclusive nonempty character directories; flat saves and stashes use file transactions.
- (NSString *)directoryRoot:(NSDictionary *)meta previous:(NSDictionary *)old key:(NSString *)key {
    NSDictionary *g = meta[@"groups"][key]; NSString *root = g[@"root"];
    if (![g[@"kind"] isEqual:@"character"] || ![root isEqual:[g[@"name"] stringByAppendingString:@"/"]] || ![old[@"root"] isEqual:root] || ![old[@"current"][@"files"] count] || ![g[@"current"][@"files"] count]) return nil;
    for (NSDictionary *m in @[old[@"current"], old[@"backup"] ?: NSNull.null, g[@"current"]]) {
        if ((id)m == NSNull.null) continue;
        for (NSDictionary *f in m[@"files"]) if (![f[@"path"] hasPrefix:root]) return nil;
    }
    return root;
}
- (BOOL)verifySubtree:(NSString *)directory root:(NSString *)root manifest:(NSDictionary *)manifest allowMissing:(BOOL)allow error:(NSError **)e {
    BOOL missing; NSArray *files = [self filesIn:directory missing:&missing error:e];
    if (missing) return allow ? YES : DMNASIssue(e, DMNASDataError, "DirectoryMissing", 0);
    if (!files) return NO;
    NSMutableArray *expected = [NSMutableArray array];
    NSArray *registered = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"files"] : @[];
    for (NSDictionary *f in registered) {
        if (![f[@"path"] hasPrefix:root]) return DMNASIssue(e, DMNASDataError, "DirectoryOwnerInvalid", 0);
        [expected addObject:@{@"path":[f[@"path"] substringFromIndex:root.length]}];
    }
    return [self verifyFiles:files manifest:@{@"files":expected} error:e];
}
- (BOOL)finishGroup:(NSDictionary *)meta error:(NSError **)e {
    if (self.activity) self.activity(DMNASActivityVerifying);
    NSArray *files = [self filesIn:@"save/" error:e]; if (!files) return NO;
    if (![self verifyFiles:files manifest:[self aggregate:meta slot:@"current"] error:e] || ![self verify:[self aggregate:meta slot:@"backup"] directory:@"backup/" error:e]) return NO;
    self.publishedListing = files;
    return [self writeJSON:meta path:metadataPath error:e] && [self removeRemote:transactionPath error:e] && [self removeRemote:uploadPath error:e] && [self removeRemote:@".d2r-upload.json" error:e];
}
- (BOOL)recoverDirectory:(NSDictionary *)input fresh:(BOOL)fresh error:(NSError **)e {
    NSDictionary *meta = input[@"metadata"], *old = input[@"previous"]; NSString *key = input[@"group"];
    if (![input[@"format"] isEqual:@4] || ![input[@"mode"] isEqual:@"directory"] || ![meta isKindOfClass:NSDictionary.class] || ![meta[@"format"] isEqual:@4] || ![self validGroups:meta error:e] || !str(key) || !meta[@"groups"][key] || ![old isKindOfClass:NSDictionary.class] || ![self validGroups:@{@"format":@4, @"id":meta[@"id"], @"groups":@{key:old}} error:e] || !number(input[@"cursor"]) || [input[@"cursor"] doubleValue] < 0 || [input[@"cursor"] doubleValue] != [input[@"cursor"] unsignedIntegerValue] || [input[@"cursor"] unsignedIntegerValue] > 3) return DMNASIssue(e, DMNASDataError, "DirectoryTransactionInvalid", 0);
    NSString *root = [self directoryRoot:meta previous:old key:key];
    if (!root || ![wireValue(meta[@"groups"][key][@"backup"]) isEqual:wireValue(old[@"current"])]) return DMNASIssue(e, DMNASDataError, "DirectoryTransactionOwnerInvalid", 0);
    NSString *suffix = [escaped([root substringToIndex:root.length - 1]) stringByAppendingString:@"/"];
    NSString *current = [@"save/" stringByAppendingString:suffix], *backup = [@"backup/" stringByAppendingString:suffix], *staged = [uploadPath stringByAppendingString:suffix];
    NSUInteger cursor = [input[@"cursor"] unsignedIntegerValue]; self.activityKind = @"character";
    // 新事务复用本轮刚完成的暂存检查；恢复必须重新检查，不能信任上次进程的观察。
    // Fresh transactions reuse this attempt's staging check; recovery must recheck rather than trust a previous process.
    if (!fresh) {
        if (cursor < 2) { if (![self verify:meta[@"groups"][key][@"current"] directory:uploadPath error:e]) return NO; }
        else {
            BOOL missing; NSArray *files = [self filesIn:uploadPath missing:&missing error:e]; if (!files && !missing) return NO;
            NSSet *allowed = [NSSet setWithArray:[meta[@"groups"][key][@"current"][@"files"] valueForKey:@"path"]];
            for (NSDictionary *f in files) if (![allowed containsObject:f[@"path"]]) return DMNASIssue(e, DMNASDataError, "StagedUnknown", 0);
        }
    }
    NSMutableDictionary *txn = [input mutableCopy]; self.uploadingBatch = YES;
    @try {
        for (; cursor < 3; cursor++) {
            if (cursor == 0) {
                // 只删除该角色已登记的备份；丢失 DELETE 响应后目录缺失可安全重放。
                // Delete only this character's registered backup; a missing directory safely replays a lost DELETE response.
                if (!fresh && ![self verifySubtree:backup root:root manifest:old[@"backup"] allowMissing:YES error:e]) return NO;
                if (![self removeRemote:backup error:e]) return NO;
            } else {
                NSString *source = cursor == 1 ? current : staged, *target = cursor == 1 ? backup : current;
                NSDictionary *manifest = cursor == 1 ? old[@"current"] : meta[@"groups"][key][@"current"];
                BOOL sourcePresent = YES, targetPresent = NO;
                if (!fresh) {
                    if (![self exists:source present:&sourcePresent error:e] || ![self exists:target present:&targetPresent error:e]) return NO;
                    if (sourcePresent == targetPresent) return DMNASIssue(e, DMNASDataError, "DirectoryTransactionAmbiguous", 0);
                    if (![self verifySubtree:sourcePresent ? source : target root:root manifest:manifest allowMissing:NO error:e]) return NO;
                }
                if (sourcePresent && ![self move:source to:target overwrite:NO error:e]) return NO;
            }
            txn[@"cursor"] = @(cursor + 1);
            if (![self writeJSON:txn path:transactionPath error:e]) return NO;
        }
    } @finally { self.uploadingBatch = NO; }
    return [self finishGroup:meta error:e];
}
- (BOOL)recoverGroup:(NSDictionary *)input error:(NSError **)e {
    return [self recoverGroup:input created:[NSMutableSet set] fresh:NO error:e];
}
- (BOOL)recoverGroup:(NSDictionary *)input created:(NSMutableSet *)created fresh:(BOOL)fresh error:(NSError **)e {
    NSDictionary *meta = input[@"metadata"], *old = input[@"previous"];
    NSString *key = input[@"group"];
    if (![meta isKindOfClass:NSDictionary.class] || ![meta[@"format"] isEqual:@4] || ![self validGroups:meta error:e] || !str(key) || !meta[@"groups"][key] || !number(input[@"cursor"]) || [input[@"cursor"] doubleValue] < 0 || [input[@"cursor"] doubleValue] != [input[@"cursor"] unsignedIntegerValue]) return DMNASIssue(e, DMNASDataError, "TransactionInvalid", 0);
    self.activityKind = meta[@"groups"][key][@"kind"];
    // 验证上一版分组并推导命令，不执行外部提供的路径。
    // Validate the previous group and derive commands; never execute supplied paths.
    if ((id)old != NSNull.null && (![old isKindOfClass:NSDictionary.class] || ![self validGroups:@{@"format":@4, @"id":meta[@"id"], @"groups":@{key:old}} error:e])) return NO;
    NSDictionary *previous = (id)old == NSNull.null ? nil : old;
    if (![wireValue(meta[@"groups"][key][@"backup"]) isEqual:wireValue(previous[@"current"] ?: NSNull.null)]) return DMNASIssue(e, DMNASDataError, "TransactionBackupInvalid", 0);
    NSArray *steps = [self groupSteps:meta key:key old:previous]; NSUInteger cursor = [input[@"cursor"] unsignedIntegerValue];
    if (cursor > steps.count) return DMNASIssue(e, DMNASDataError, "TransactionCursorInvalid", 0);
    NSUInteger publishStart = steps.count - [meta[@"groups"][key][@"current"][@"files"] count];
    if (!fresh && cursor < publishStart && ![self verify:meta[@"groups"][key][@"current"] directory:uploadPath error:e]) return NO;
    // 继续修改前拒绝未登记或改名的暂存文件。
    // Reject stray or renamed staged files before making any further changes.
    if (!fresh) {
        BOOL staged; if (![self exists:uploadPath present:&staged error:e]) return NO;
        if (staged) {
            NSArray *files = [self filesIn:uploadPath error:e]; if (!files) return NO;
            NSSet *allowed = [NSSet setWithArray:[meta[@"groups"][key][@"current"][@"files"] valueForKey:@"path"]];
            for (NSDictionary *f in files) if (![allowed containsObject:f[@"path"]]) return DMNASIssue(e, DMNASDataError, "StagedUnknown", 0);
        }
    }
    NSMutableDictionary *txn = [input mutableCopy];
    NSUInteger backupStart = [previous[@"backup"] isKindOfClass:NSDictionary.class] ? [previous[@"backup"][@"files"] count] : 0;
    self.uploadingBatch = YES;
    @try {
        for (; cursor < steps.count; cursor++) {
            NSDictionary *step = steps[cursor];
            if (step[@"delete"]) { if (![self removeRemote:step[@"delete"] error:e]) return NO; }
            else {
                BOOL source = YES, target;
                if (!fresh && ![self exists:step[@"from"] present:&source error:e]) return NO;
                if (source) {
                    if (![self parents:step[@"to"] created:created error:e] || ![self move:step[@"from"] to:step[@"to"] overwrite:NO error:e]) return NO;
                } else if (![self exists:step[@"to"] present:&target error:e] || !target) return DMNASIssue(e, DMNASDataError, "TransactionMissing", 0);
            }
            // 删除、备份、发布三阶段的边界必须持久化；阶段内操作可安全重放。
            // Persist boundaries between deletion, backup and publication; operations within a phase replay safely.
            // 边界写入失败立即停止，避免把新发布的文件误当成待备份旧文件。
            // Stop on a failed boundary write so newly published files can never be mistaken for old files to back up.
            NSUInteger next = cursor + 1;
            if (next == backupStart || next == publishStart || next == steps.count) {
                txn[@"cursor"] = @(next); if (![self writeJSON:txn path:transactionPath error:e]) return NO;
            }
        }
    } @finally { self.uploadingBatch = NO; }
    return [self finishGroup:meta error:e];
}
- (NSDictionary *)publishGroup:(NSDictionary *)version descriptor:(NSDictionary *)descriptor key:(NSString *)key meta:(NSDictionary *)input source:(NSString *)source error:(NSError **)e {
    NSTimeInterval started = NSProcessInfo.processInfo.systemUptime; NSUInteger requests = self.requestCount;
    @try {
        self.activityKind = descriptor[@"kind"]; self.publishedListing = nil;
        if (![self upload:version source:source directory:uploadPath error:e] || ![self verify:version directory:uploadPath error:e]) return nil;
        NSMutableDictionary *meta = [input mutableCopy], *groups = [input[@"groups"] mutableCopy]; NSDictionary *old = groups[key];
        groups[key] = @{@"kind":descriptor[@"kind"], @"name":descriptor[@"name"], @"root":descriptor[@"root"], @"current":version, @"backup":old[@"current"] ?: NSNull.null};
        meta[@"groups"] = groups; meta[@"id"] = NSUUID.UUID.UUIDString;
        if (![self validGroups:meta error:e] || ![self mkdir:@"save/" error:e] || ![self mkdir:@"backup/" error:e]) return nil;
        NSString *root = [self directoryRoot:meta previous:old key:key];
        if (root) {
            NSString *backup = [@"backup/" stringByAppendingString:[escaped([root substringToIndex:root.length - 1]) stringByAppendingString:@"/"]];
            if (![self verifySubtree:backup root:root manifest:old[@"backup"] allowMissing:(id)old[@"backup"] == NSNull.null error:e]) return nil;
        }
        NSMutableDictionary *txn = [@{@"format":root ? @4 : @3, @"metadata":meta, @"previous":old ?: NSNull.null, @"group":key, @"cursor":@0} mutableCopy];
        if (root) txn[@"mode"] = @"directory";
        NSMutableSet *created = [NSMutableSet setWithArray:@[@"save/", @"backup/"]];
        if (![self writeJSON:txn path:transactionPath error:e]) return nil;
        if (root ? ![self recoverDirectory:txn fresh:YES error:e] : ![self recoverGroup:txn created:created fresh:YES error:e]) return nil;
        NSString *objects = [self path:@"objects"]; BOOL cached = [FM() createDirectoryAtPath:objects withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSDictionary *f in version[@"files"]) {
            NSData *data = source ? [NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:f[@"path"]]] : [self object:f error:nil];
            if (!data || !hex(f[@"sha256"]) || ![data writeToFile:[objects stringByAppendingPathComponent:f[@"sha256"]] options:NSDataWritingAtomic error:nil]) cached = NO;
        }
        NSArray *listing = cached ? self.publishedListing : nil;
        if (listing) [self rememberCurrent:[self aggregate:meta slot:@"current"] listing:listing error:nil];
        if (![self rememberGroups:meta error:e]) return nil;
        return meta;
    } @finally {
        // 仅记录分组类型、数量和耗时，不记录名称、路径或内容。
        // Log only group kind, counts and elapsed time, never names, paths or contents.
        NSString *kind = [descriptor[@"kind"] isEqual:@"character"] ? @"character" : [descriptor[@"kind"] isEqual:@"stash"] ? @"stash" : @"auxiliary";
        fprintf(stderr, "NAS publish kind=%s files=%lu requests=%lu seconds=%.3f\n", kind.UTF8String, (unsigned long)[version[@"files"] count], (unsigned long)(self.requestCount - requests), NSProcessInfo.processInfo.systemUptime - started);
    }
}
- (BOOL)acceptGroup:(NSDictionary *)m key:(NSString *)key state:(NSMutableDictionary *)state error:(NSError **)e {
    state[key] = @{@"revision":m[@"id"], @"digest":m[@"digest"], @"savedAt":m[@"savedAt"]};
    return putJSON(@{@"format":@4, @"groups":state}, [self path:@"state.json"], e);
}
- (BOOL)sync:(NSString *)source save:(NSString *)save allowDownload:(BOOL)allow error:(NSError **)e {
    return [self sync:source save:save groups:nil allowDownload:allow error:e];
}
- (BOOL)sync:(NSString *)source save:(NSString *)save groups:(NSSet<NSString *> *)selected allowDownload:(BOOL)allow error:(NSError **)e {
    self.knownDirectories = [NSMutableSet set]; self.markerRead = NO; self.observedMarker = nil; self.publishedListing = nil;
    @try { return [self syncAttempt:source save:save groups:selected allowDownload:allow error:e]; }
    @finally { self.knownDirectories = nil; self.markerRead = NO; self.observedMarker = nil; self.publishedListing = nil; }
}
- (BOOL)syncAttempt:(NSString *)source save:(NSString *)save groups:(NSSet<NSString *> *)selected allowDownload:(BOOL)allow error:(NSError **)e {
    self.needsRestart = NO; self.restartGroups = [NSSet set];
    NSMutableSet *blockedGroups = [NSMutableSet set];
    if (![self prepare:e] || ![self recover:e]) return NO;
    id previousState = readJSON([self path:@"state.json"]); if (![previousState isKindOfClass:NSDictionary.class]) previousState = @{};
    NSMutableDictionary *state = [previousState[@"groups"] isKindOfClass:NSDictionary.class] ? [previousState[@"groups"] mutableCopy] : [NSMutableDictionary dictionary];
    NSDictionary *candidate = readJSON([self path:@"candidate.json"]);
    NSDictionary *whole = [self snapshot:source savedAt:0 error:e]; if (!whole) return NO;
    if (validManifest(candidate, nil) && [candidate[@"digest"] isEqual:whole[@"digest"]]) whole = candidate;
    if (!putJSON(whole, [self path:@"candidate.json"], e)) return NO;
    BOOL missing; NSDictionary *meta = [self groupMetadata:&missing error:e]; if (!meta && !missing) return NO;
    if (meta && ![self rememberGroups:meta error:e]) return NO;
    if (!meta) meta = @{@"format":@4, @"id":NSUUID.UUID.UUIDString, @"groups":@{}};
    NSDictionary *local = DMNASGroups(whole, meta[@"groups"], e); if (!local) return NO;
    id restore = readJSON([self path:@"restore.json"]); if (![restore isKindOfClass:NSDictionary.class]) restore = nil;
    if (restore && (!str(restore[@"group"]) || !meta[@"groups"][restore[@"group"]] || !validManifest(restore[@"manifest"], e))) return DMNASIssue(e, DMNASDataError, "RestoreRequestInvalid", 0);
    if (restore && !allow) { self.needsRestart = YES; self.message = @(dm_ui("dmNasRestoreScheduled")); return YES; }
    NSMutableDictionary *restoreManifests = [NSMutableDictionary dictionary];
    if (restore) restoreManifests[restore[@"group"]] = restore[@"manifest"];
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSMutableSet *keys = [NSMutableSet setWithArray:local.allKeys]; [keys addObjectsFromArray:[meta[@"groups"] allKeys]]; [keys addObjectsFromArray:restoreManifests.allKeys];
    NSArray *ordered = [keys.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int x = [a hasPrefix:@"character:"] ? 0 : [a hasPrefix:@"stash:"] ? 1 : 2;
        int y = [b hasPrefix:@"character:"] ? 0 : [b hasPrefix:@"stash:"] ? 1 : 2;
        return x == y ? [a compare:b options:NSLiteralSearch] : x < y ? NSOrderedAscending : NSOrderedDescending;
    }];
    id savedCandidates = readJSON([self path:@"group-candidates.json"]);
    NSMutableDictionary *candidates = [savedCandidates isKindOfClass:NSDictionary.class] ? [savedCandidates mutableCopy] : [NSMutableDictionary dictionary];
    BOOL apply = NO;
    for (NSString *key in ordered) {
        NSDictionary *descriptor = meta[@"groups"][key] ?: local[key] ?: restoreManifests[key], *remote = meta[@"groups"][key][@"current"];
        NSMutableDictionary *l = [(local[key] ?: [self emptyGroup:descriptor stamp:[whole[@"savedAt"] doubleValue]]) mutableCopy];
        NSDictionary *saved = candidates[key];
        if (validManifest(saved, nil) && [saved[@"digest"] isEqual:l[@"digest"]]) { l[@"id"] = saved[@"id"]; l[@"savedAt"] = saved[@"savedAt"]; }
        // 首次发布可能先于本机确认落盘；替换为更新存档前先识别已固定的候选版本。
        // A first upload may have published before its local acknowledgement was
        // saved. Recognize our pinned candidate before replacing it with a newer save.
        if (!state[key] && [saved[@"id"] isEqual:remote[@"id"]] && [remote[@"device"] isEqual:self.device]) {
            if (![self acceptGroup:remote key:key state:state error:e]) return NO;
        }
        candidates[key] = l;
        if (!putJSON(candidates, [self path:@"group-candidates.json"], e)) return NO;
        merged[key] = l;
        if (selected && ![selected containsObject:key]) continue;
        BOOL restored = restoreManifests[key] != nil;
        if (restored) {
            if (!validManifest(restoreManifests[key], e)) return NO;
            l = [restoreManifests[key] mutableCopy]; l[@"id"] = NSUUID.UUID.UUIDString; l[@"savedAt"] = @(NSDate.date.timeIntervalSince1970); merged[key] = l;
            self.downloadRoot = nil; apply = YES;
        }
        NSDictionary *s = state[key];
        if ([remote[@"digest"] isEqual:l[@"digest"]]) { if (![self acceptGroup:remote key:key state:state error:e]) return NO; continue; }
        BOOL lc = !s || ![s[@"digest"] isEqual:l[@"digest"]];
        BOOL rc = remote && (!s || ![s[@"revision"] isEqual:remote[@"id"]]);
        BOOL remoteWins = !restored && remote && (!s || (rc && [remote[@"external"] boolValue]) || (!lc && rc) || (lc && rc && ([remote[@"savedAt"] doubleValue] > [l[@"savedAt"] doubleValue] || ([remote[@"savedAt"] isEqual:l[@"savedAt"]] && [remote[@"id"] compare:l[@"id"]] == NSOrderedDescending))));
        if (remoteWins) {
            if (!allow) { self.needsRestart = YES; [blockedGroups addObject:key]; self.restartGroups = blockedGroups; continue; }
            merged[key] = remote; apply = YES;
        } else {
            l[@"parent"] = remote[@"id"] ?: @"";
            self.downloadRoot = restored ? nil : @"save/";
            NSDictionary *next = [self publishGroup:l descriptor:descriptor key:key meta:meta source:restored ? nil : source error:e]; if (!next) return NO;
            meta = next;
            if (![self acceptGroup:l key:key state:state error:e]) return NO;
            if (self.groupFinished) self.groupFinished(key, descriptor[@"kind"]);
        }
    }
    if (apply) {
        NSMutableArray *files = [NSMutableArray array];
        for (NSDictionary *m in merged.allValues) [files addObjectsFromArray:m[@"files"]];
        [files sortUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch]; }];
        // 同时固定保留的本机内容；apply() 会原子重建整个目录树。
        // Pin surviving local bytes as well: apply() reconstructs the entire tree atomically.
        NSString *objects = [self path:@"objects"];
        if (![FM() createDirectoryAtPath:objects withIntermediateDirectories:YES attributes:nil error:e]) return NO;
        for (NSString *key in local) for (NSDictionary *f in local[key][@"files"]) {
            NSData *data = [NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:f[@"path"]] options:0 error:e];
            if (!data || ![data writeToFile:[objects stringByAppendingPathComponent:f[@"sha256"]] options:NSDataWritingAtomic error:e]) return NO;
        }
        NSDictionary *combined = @{@"format":@1, @"id":NSUUID.UUID.UUIDString, @"parent":@"", @"device":self.device, @"savedAt":whole[@"savedAt"], @"files":files, @"digest":digest(files)};
        self.downloadRoot = nil; if (![self apply:combined save:save error:e]) return NO;
        for (NSString *key in merged) {
            NSDictionary *r = meta[@"groups"][key][@"current"];
            if ([r[@"digest"] isEqual:merged[key][@"digest"]]) {
                if (![self acceptGroup:r key:key state:state error:e]) return NO;
                if (self.groupFinished && ![r[@"digest"] isEqual:local[key][@"digest"]]) self.groupFinished(key, meta[@"groups"][key][@"kind"]);
            }
        }
    }
    if (restore && allow) [FM() removeItemAtPath:[self path:@"restore.json"] error:nil];
    self.message = self.needsRestart ? @(dm_ui("dmNasRestartRequired")) : @(dm_ui("dmSyncComplete"));
    return YES;
}
- (NSArray<NSDictionary *> *)history:(NSError **)e {
    if (![self prepare:e] || ![self recover:e]) return nil;
    BOOL missing; NSDictionary *stored = [self storedMetadata:&missing error:e]; if (!stored) return missing ? @[] : nil;
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *key in [stored[@"groups"] allKeys]) {
        NSDictionary *g = stored[@"groups"][key], *b = g[@"backup"]; if ((id)b == NSNull.null) continue;
        NSMutableDictionary *v = [b mutableCopy]; v[@"group"] = key; v[@"kind"] = g[@"kind"]; v[@"name"] = g[@"name"];
        // 恢复标识同时固定版本与分组。
        // Restore identifiers pin both the revision and its group.
        v[@"id"] = [NSString stringWithFormat:@"%@|%@", b[@"id"], key]; [result addObject:v];
    }
    [result sortUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"group"] compare:b[@"group"] options:NSLiteralSearch]; }];
    return result;
}
- (BOOL)scheduleRestore:(NSString *)revision error:(NSError **)e {
    NSArray *versions = [self history:e]; if (!versions) return NO;
    NSDictionary *chosen = nil; for (NSDictionary *v in versions) if ([v[@"id"] isEqual:revision]) chosen = v;
    if (!chosen) return DMNASIssue(e, DMNASBackupError, "BackupReplaced", 0);
    BOOL missing; NSDictionary *meta = [self storedMetadata:&missing error:e]; if (!meta) return NO;
    NSDictionary *listing = [self describeBackup:e]; if (!listing) return NO;
    NSDictionary *split = DMNASGroups(listing, meta[@"groups"], e); if (!split) return NO;
    NSString *key = chosen[@"group"];
    self.activityGroups = meta[@"groups"];
    self.readPaths = [NSSet setWithArray:[split[key][@"files"] valueForKey:@"path"] ?: @[]];
    NSDictionary *actual;
    @try { actual = [self adopt:@"backup/" error:e]; } @finally { self.readPaths = nil; }
    if (!actual) return NO;
    return putJSON(@{@"group":key, @"revision":revision, @"manifest":actual}, [self path:@"restore.json"], e);
}
