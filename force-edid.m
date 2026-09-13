// force-edid — apply a custom EDID to a SPECIFIC external display on Apple Silicon.
//
// On Apple Silicon the DCP (Display CoProcessor) handles displays and the classic
// /Library/Displays override plists are ignored. This uses the private IOKit
// function IOAVServiceSetVirtualEDIDMode to inject an EDID at runtime, which makes
// macOS re-negotiate with the new timings — no reboot.
//
// This build is display-targeted: with more than one external display connected it
// refuses to touch anything unless you identify the target (by --vendor/--product of
// its CURRENT EDID, --name, or --location), so it won't clobber your other monitor.
//
// Build:  clang -framework Foundation -framework IOKit -o force-edid force-edid.m

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceCopyEDID(IOAVServiceRef service, CFDataRef *edidData);
extern IOReturn IOAVServiceSetVirtualEDIDMode(IOAVServiceRef service, uint32_t mode, CFDataRef edidData);

// ---- tiny EDID decode --------------------------------------------------------

static uint16_t edidVendorRaw(const uint8_t *e, size_t n) { return n < 10 ? 0 : (uint16_t)((e[8] << 8) | e[9]); }
static uint16_t edidProduct(const uint8_t *e, size_t n)   { return n < 12 ? 0 : (uint16_t)(e[10] | (e[11] << 8)); }

static void edidVendorCode(uint16_t v, char out[4]) {
    out[0] = 'A' + ((v >> 10) & 0x1f) - 1;
    out[1] = 'A' + ((v >> 5) & 0x1f) - 1;
    out[2] = 'A' + (v & 0x1f) - 1;
    out[3] = 0;
}

// First detailed-timing active pixels, for a friendly print.
static void edidPreferred(const uint8_t *e, size_t n, int *w, int *h) {
    *w = *h = 0;
    if (n < 72) return;
    const uint8_t *d = e + 54;
    if (d[0] == 0 && d[1] == 0) return; // not a timing descriptor
    *w = d[2] | ((d[4] & 0xf0) << 4);
    *h = d[5] | ((d[7] & 0xf0) << 4);
}

// Monitor name from a 0xFC descriptor, else NULL. Caller frees.
static char *edidName(const uint8_t *e, size_t n) {
    if (n < 128) return NULL;
    for (int off = 54; off <= 108; off += 18) {
        if (e[off] == 0 && e[off+1] == 0 && e[off+2] == 0 && e[off+3] == 0xfc) {
            char buf[14]; int k = 0;
            for (int i = 5; i < 18; i++) { char c = e[off+i]; if (c == '\n') break; buf[k++] = c; }
            while (k > 0 && buf[k-1] == ' ') k--;
            buf[k] = 0;
            if (k > 0) return strdup(buf);
        }
    }
    return NULL;
}

// Case-insensitive substring test against the monitor name (0xFC descriptor).
static BOOL edidNameContains(const uint8_t *e, size_t n, NSString *sub) {
    char *nm = edidName(e, n);
    if (!nm) return NO;
    NSString *s = [NSString stringWithUTF8String:nm];
    free(nm);
    return s && [s rangeOfString:sub options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// ---- service enumeration -----------------------------------------------------

typedef struct { io_service_t service; IOAVServiceRef av; NSString *location; NSData *edid; } Display;

static NSString *serviceLocation(io_service_t s) {
    CFStringRef loc = IORegistryEntrySearchCFProperty(
        s, kIOServicePlane, CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    return loc ? [(NSString *)loc autorelease] : nil;
}

// Collect external (non-embedded) DCPAVServiceProxy displays with their current EDID.
static NSMutableArray *collectDisplays(void) {
    NSMutableArray *out = [NSMutableArray array];
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) != KERN_SUCCESS)
        return out;

    io_service_t s;
    while ((s = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        NSString *loc = serviceLocation(s);
        if (loc && [loc isEqualToString:@"Embedded"]) { IOObjectRelease(s); continue; }

        IOAVServiceRef av = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
        if (!av) { IOObjectRelease(s); continue; }

        CFDataRef cur = NULL; NSData *edid = nil;
        if (IOAVServiceCopyEDID(av, &cur) == kIOReturnSuccess && cur) {
            edid = [(NSData *)cur autorelease];
        }

        Display *d = malloc(sizeof(Display));
        d->service = s; d->av = av; d->location = loc; d->edid = edid;
        [out addObject:[NSValue valueWithPointer:d]];
    }
    IOObjectRelease(it);
    return out;
}

// One-line, labeled description of a display's EDID. Labels mirror the matcher flags
// (--name / --vendor / --product) so it's clear which value is which. Caller frees.
static char *edidDescription(NSData *edid) {
    if (!edid) return strdup("(no EDID)");
    const uint8_t *e = edid.bytes; size_t n = edid.length;
    uint16_t v = edidVendorRaw(e, n), p = edidProduct(e, n);
    char code[4]; edidVendorCode(v, code);
    char *name = edidName(e, n);
    char namebuf[64];
    if (name) snprintf(namebuf, sizeof namebuf, "\"%s\"", name);
    else      snprintf(namebuf, sizeof namebuf, "(unnamed)");
    char *out = NULL;
    asprintf(&out, "name=%-16s vendor=0x%04x  product=0x%04x  pnp-code=%s  edid=%zuB",
             namebuf, v, p, code, n);
    free(name);
    return out;
}

// Preferred resolution as "WxH" (or "0x0" if unknown). Written into buf.
static void edidResString(NSData *edid, char *buf, size_t bufsz) {
    int w = 0, h = 0; if (edid) edidPreferred(edid.bytes, edid.length, &w, &h);
    snprintf(buf, bufsz, "%dx%d", w, h);
}

// Full one-line summary of a display: EDID fields + location + resolution. Caller frees.
// Every place that prints a display uses this, so the format stays consistent.
static char *displayLine(Display *d) {
    char *desc = edidDescription(d->edid);
    char res[16]; edidResString(d->edid, res, sizeof res);
    char *out = NULL;
    asprintf(&out, "%s  location=%s  res=%s", desc, d->location ? d->location.UTF8String : "(null)", res);
    free(desc);
    return out;
}

static void describeEdid(NSData *edid) {
    char *desc = edidDescription(edid);
    printf("%s", desc);
    free(desc);
}

// ---- commands ----------------------------------------------------------------

// Print the human-readable display list (used by `list` and by match-failure messages).
static void printDisplayList(NSArray *ds, FILE *out) {
    if (ds.count == 0) { fprintf(out, "No external DCPAVServiceProxy displays found.\n"); return; }
    fprintf(out, "External displays (%lu):\n", (unsigned long)ds.count);
    for (NSValue *val in ds) {
        Display *d = val.pointerValue;
        char *line = displayLine(d);
        fprintf(out, "  • %s\n", line);
        free(line);
    }
}

static int cmdList(void) {
    printDisplayList(collectDisplays(), stdout);
    return 0;
}

// A display selector. vendor/product are -1 when unset; location/name are nil when unset.
typedef struct { int vendor, product; NSString *location, *name; } Filter;
static BOOL filterActive(Filter f) { return f.vendor >= 0 || f.product >= 0 || f.location || f.name; }

static BOOL matches(Display *d, Filter f) {
    if (f.location && !(d->location && [d->location isEqualToString:f.location])) return NO;
    if (f.name) {
        if (!d->edid) return NO;
        if (!edidNameContains(d->edid.bytes, d->edid.length, f.name)) return NO;
    }
    if (f.vendor >= 0 || f.product >= 0) {
        if (!d->edid) return NO;
        const uint8_t *e = d->edid.bytes; size_t n = d->edid.length;
        if (f.vendor >= 0 && edidVendorRaw(e, n) != (uint16_t)f.vendor) return NO;
        if (f.product >= 0 && edidProduct(e, n) != (uint16_t)f.product) return NO;
    }
    return YES;
}

// Find the single display matching the filter; returns NULL (with a message) on 0 or >1.
static Display *matchOne(NSArray *ds, Filter f);

static int applyOrReset(NSData *edid, BOOL reset, Filter f) {
    Display *d = matchOne(collectDisplays(), f);
    if (!d) return 1;

    char *line = displayLine(d);
    printf("Target: %s\n", line);
    free(line);

    IOReturn r = reset
        ? IOAVServiceSetVirtualEDIDMode(d->av, 0, NULL)
        : IOAVServiceSetVirtualEDIDMode(d->av, 1, (__bridge CFDataRef)edid);

    if (r != kIOReturnSuccess) {
        fprintf(stderr, "  ✗ failed (IOReturn 0x%x)%s\n", r, r == kIOReturnNotPrivileged ? " — try sudo" : "");
        return 1;
    }
    printf("  ✓ %s\n\nDone. The display may flicker as it re-negotiates.\n",
           reset ? "reset to original EDID" : "custom EDID applied");
    return 0;
}

static int cmdDump(NSString *outPath, Filter f) {
    Display *d = matchOne(collectDisplays(), f);
    if (!d) return 1;
    if (!d->edid) { fprintf(stderr, "Matched display has no readable EDID.\n"); return 1; }
    if (![d->edid writeToFile:outPath atomically:YES]) { fprintf(stderr, "Cannot write %s\n", outPath.UTF8String); return 1; }
    printf("Wrote %lu bytes to %s\n", (unsigned long)d->edid.length, outPath.UTF8String);
    return 0;
}

// ---- hybrid building (shared by graft + update) ------------------------------

static uint8_t blockSum(const uint8_t *p) { uint32_t s = 0; for (int i = 0; i < 128; i++) s += p[i]; return (uint8_t)(s & 0xff); }
static void fixChecksum(uint8_t *b) { uint32_t s = 0; for (int i = 0; i < 127; i++) s += b[i]; b[127] = (uint8_t)((256 - (s & 0xff)) & 0xff); }

// Build a hybrid EDID from a display's live base EDID and a <source> EDID. The base supplies
// the IDENTITY (vendor + basic-display block) — keeping it is what stops WindowServer from
// rebuilding the layout and dropping sibling displays — while <source> supplies the timing.
//   timingOnly=YES → keep the whole base EDID, overwrite only the preferred detailed timing
//                    (bytes 54..71). Identity-preserving; leaves any base extension untouched.
//   timingOnly=NO  → base identity block + source's full descriptor region (bytes 54..125:
//                    preferred DTD + range limits + monitor name + serial) + source's extension
//                    block(s) (CEA/HDR), with the extension count taken from source.
//   bump=YES       → set the product id to (source's product + bumpBy); else keep base's product.
// Returns a new, checksum-fixed & verified NSData, or nil on error (message to stderr).
static NSData *buildHybrid(NSData *baseData, NSData *srcData, BOOL timingOnly, BOOL bump, int bumpBy) {
    const uint8_t *base = baseData.bytes; size_t baseLen = baseData.length;
    const uint8_t *src  = srcData.bytes;  size_t srcLen  = srcData.length;
    if (baseLen < 128) { fprintf(stderr, "Base EDID too small (%zu bytes).\n", baseLen); return nil; }
    if (srcLen  < 72)  { fprintf(stderr, "Source EDID too small (%zu bytes).\n", srcLen); return nil; }

    uint16_t newProduct = bump ? (uint16_t)(edidProduct(src, srcLen) + bumpBy)
                               : edidProduct(base, baseLen);

    NSMutableData *out;
    if (timingOnly) {
        out = [baseData mutableCopy];
        uint8_t *b = out.mutableBytes;
        memcpy(b + 54, src + 54, 18);              // preferred detailed timing only
        b[10] = newProduct & 0xff; b[11] = (newProduct >> 8) & 0xff;
        fixChecksum(b);                            // base block; extensions left as-is
    } else {
        int extCount = src[126];
        if (srcLen < (size_t)(128 + 128 * extCount)) {
            fprintf(stderr, "Source EDID truncated: declares %d extension block(s) but is %zu bytes.\n", extCount, srcLen);
            return nil;
        }
        out = [NSMutableData dataWithLength:128];
        uint8_t *b = out.mutableBytes;
        memcpy(b, base, 128);                      // identity block (vendor + basic params)
        memcpy(b + 54, src + 54, 72);              // full descriptors: DTD + range + name + serial
        b[10] = newProduct & 0xff; b[11] = (newProduct >> 8) & 0xff;
        b[126] = (uint8_t)extCount;                // declare source's extension count
        fixChecksum(b);
        if (extCount > 0) [out appendBytes:src + 128 length:(NSUInteger)(128 * extCount)];
    }

    const uint8_t *ob = out.bytes; size_t olen = out.length;    // verify every block sums to 0
    for (size_t off = 0; off + 128 <= olen; off += 128) {
        if (blockSum(ob + off) != 0) { fprintf(stderr, "Checksum verification failed at block offset %zu.\n", off); return nil; }
    }
    return out;
}

static Display *matchOne(NSArray *ds, Filter f) {
    Display *found = NULL; int n = 0;
    for (NSValue *v in ds) { Display *d = v.pointerValue; if (matches(d, f)) { found = d; n++; } }
    if (n != 1) {
        if (n == 0) fprintf(stderr, "No display matched the filter.\n");
        else        fprintf(stderr, "Filter matched %d displays — narrow it with --name/--vendor/--product.\n", n);
        fprintf(stderr, "\n");
        printDisplayList(ds, stderr);
        return NULL;
    }
    return found;
}

// graft — low-level: build a hybrid FILE from the matched display's identity + <source> timing.
static int cmdGraft(NSString *sourcePath, NSString *outPath, Filter f) {
    if (!sourcePath || !outPath) { fprintf(stderr, "Error: graft needs <source.bin> and -o <out.bin>.\n"); return 1; }
    NSData *src = [NSData dataWithContentsOfFile:sourcePath];
    if (!src) { fprintf(stderr, "Error: cannot read source EDID from %s\n", sourcePath.UTF8String); return 1; }

    Display *d = matchOne(collectDisplays(), f);
    if (!d) return 1;

    NSData *out = buildHybrid(d->edid, src, YES, NO, 0);
    if (!out) return 1;
    if (![out writeToFile:outPath atomically:YES]) { fprintf(stderr, "Cannot write %s\n", outPath.UTF8String); return 1; }
    int w, h; edidPreferred(out.bytes, out.length, &w, &h);
    printf("Grafted preferred timing (%dx%d) onto identity ", w, h);
    describeEdid(d->edid); printf("\n  → wrote %lu bytes to %s\n", (unsigned long)out.length, outPath.UTF8String);
    printf("Apply it with:  force-edid apply %s --vendor 0x%x --product 0x%x\n",
           outPath.UTF8String, edidVendorRaw(d->edid.bytes, d->edid.length), edidProduct(d->edid.bytes, d->edid.length));
    return 0;
}

// update — high-level: match one display, build the hybrid from <source> (+ optional product
// bump), and APPLY it in one step. This is what the fix-*.sh scripts call.
static int cmdUpdate(NSString *sourcePath, Filter f,
                     BOOL timingOnly, BOOL bump, int bumpBy, NSString *outPath, BOOL dryRun) {
    if (!sourcePath) { fprintf(stderr, "Error: update needs <source.bin>.\n"); return 1; }
    NSData *src = [NSData dataWithContentsOfFile:sourcePath];
    if (!src) { fprintf(stderr, "Error: cannot read source EDID from %s\n", sourcePath.UTF8String); return 1; }

    Display *d = matchOne(collectDisplays(), f);
    if (!d) return 1;

    char *line = displayLine(d);
    printf("Target: %s\n", line);
    free(line);

    NSData *out = buildHybrid(d->edid, src, timingOnly, bump, bumpBy);
    if (!out) return 1;

    uint16_t v = edidVendorRaw(out.bytes, out.length), p = edidProduct(out.bytes, out.length);
    int w, h; edidPreferred(out.bytes, out.length, &w, &h);
    char *nm = edidName(out.bytes, out.length);
    printf("Built %s hybrid: identity 0x%04x/0x%04x, %dx%d, name '%s', %lu bytes\n",
           timingOnly ? "timing-only" : "full", v, p, w, h, nm ? nm : "(unnamed)", (unsigned long)out.length);
    free(nm);

    if (outPath) {
        if (![out writeToFile:outPath atomically:YES]) { fprintf(stderr, "Cannot write %s\n", outPath.UTF8String); return 1; }
        printf("  → wrote %lu bytes to %s\n", (unsigned long)out.length, outPath.UTF8String);
    }
    if (dryRun) { printf("(dry-run: not applied)\n"); return 0; }

    IOReturn r = IOAVServiceSetVirtualEDIDMode(d->av, 1, (__bridge CFDataRef)out);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "  ✗ failed (IOReturn 0x%x)%s\n", r, r == kIOReturnNotPrivileged ? " — try sudo" : "");
        return 1;
    }
    printf("  ✓ applied to the matched display\n\nDone. The display may flicker as it re-negotiates.\n");
    return 0;
}

static int parseHexInt(const char *s) { return (int)strtol(s, NULL, 0); }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "force-edid — inject a custom EDID into a specific display (Apple Silicon)\n\n"
                "Usage:\n"
                "  force-edid list\n"
                "  force-edid dump   <out.bin>        <matcher>\n"
                "  force-edid update <src.bin>        <matcher> [--timing-only] [--bump [N]] [-o <out.bin>] [--dry-run]\n"
                "  force-edid graft  <src.bin> -o <out.bin>  <matcher>\n"
                "  force-edid apply  <edid.bin>       <matcher>\n"
                "  force-edid reset                   <matcher>\n\n"
                "  update = match one display, build a hybrid from its CURRENT identity + <src.bin>,\n"
                "           and APPLY it. Default grafts <src.bin>'s full descriptors + extension\n"
                "           (name/HDR/CEA); --timing-only grafts just the preferred timing (keeps the\n"
                "           display's other descriptors, sibling-safe). --bump sets the product id to\n"
                "           <src.bin>'s product + N (default 1) so macOS treats it as a fresh display\n"
                "           and (re)detects it. -o also saves the built EDID; --dry-run builds without\n"
                "           applying. This is the one-shot command the fix-*.sh scripts call.\n"
                "  graft  = low-level: write a timing-only hybrid FILE (never applies).\n\n"
                "  <matcher> identifies ONE display by any of: --vendor 0xXXXX --product 0xYYYY (its\n"
                "  CURRENT ids), --name <substr> (case-insensitive substring of its CURRENT EDID\n"
                "  name), --location <loc>. Required when >1 external display is connected.\n");
            return 1;
        }

        const char *cmd = argv[1];
        NSString *file = nil, *outFile = nil, *wantLoc = nil, *wantName = nil; int wantV = -1, wantP = -1;
        BOOL timingOnly = NO, bump = NO, dryRun = NO; int bumpBy = 1;
        for (int i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "--vendor") && i+1 < argc) wantV = parseHexInt(argv[++i]);
            else if (!strcmp(argv[i], "--product") && i+1 < argc) wantP = parseHexInt(argv[++i]);
            else if (!strcmp(argv[i], "--location") && i+1 < argc) wantLoc = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--name") && i+1 < argc) wantName = [NSString stringWithUTF8String:argv[++i]];
            else if (!strcmp(argv[i], "--timing-only")) timingOnly = YES;
            else if (!strcmp(argv[i], "--dry-run")) dryRun = YES;
            else if (!strcmp(argv[i], "--bump")) { bump = YES; if (i+1 < argc && argv[i+1][0] != '-') { char *e; long v = strtol(argv[i+1], &e, 0); if (*e == 0) { bumpBy = (int)v; i++; } } }
            else if ((!strcmp(argv[i], "-o") || !strcmp(argv[i], "--out")) && i+1 < argc) outFile = [NSString stringWithUTF8String:argv[++i]];
            else if (argv[i][0] != '-') file = [NSString stringWithUTF8String:argv[i]];
        }

        Filter f = { wantV, wantP, wantLoc, wantName };

        if (!strcmp(cmd, "list")) return cmdList();

        if (!strcmp(cmd, "dump")) {
            if (!file) { fprintf(stderr, "Error: dump needs an <outfile.bin> path.\n"); return 1; }
            return cmdDump(file, f);
        }

        if (!strcmp(cmd, "apply")) {
            if (!file) { fprintf(stderr, "Error: apply needs an <edid.bin> path.\n"); return 1; }
            NSData *edid = [NSData dataWithContentsOfFile:file];
            if (!edid) { fprintf(stderr, "Error: cannot read %s\n", file.UTF8String); return 1; }
            if (edid.length < 128 || edid.length % 128) { fprintf(stderr, "Error: %lu bytes is not a valid EDID size.\n", (unsigned long)edid.length); return 1; }
            printf("Loaded EDID: %lu bytes from %s\n", (unsigned long)edid.length, file.UTF8String);
            return applyOrReset(edid, NO, f);
        }

        if (!strcmp(cmd, "graft")) return cmdGraft(file, outFile, f);

        if (!strcmp(cmd, "update")) return cmdUpdate(file, f, timingOnly, bump, bumpBy, outFile, dryRun);

        if (!strcmp(cmd, "reset")) return applyOrReset(nil, YES, f);

        fprintf(stderr, "Unknown command: %s\n", cmd);
        return 1;
    }
}
