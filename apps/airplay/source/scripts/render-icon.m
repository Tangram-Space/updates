/* Original vector application icon. No SF Symbols or Apple artwork are used.
 * Run on macOS; writes PNG representations only to a new iconset directory. */
#import <Cocoa/Cocoa.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    NSInteger points;
    NSInteger scale;
    const char *name;
} IconRepresentation;

static const IconRepresentation representations[] = {
    {16, 1, "icon_16x16.png"},
    {16, 2, "icon_16x16@2x.png"},
    {32, 1, "icon_32x32.png"},
    {32, 2, "icon_32x32@2x.png"},
    {128, 1, "icon_128x128.png"},
    {128, 2, "icon_128x128@2x.png"},
    {256, 1, "icon_256x256.png"},
    {256, 2, "icon_256x256@2x.png"},
    {512, 1, "icon_512x512.png"},
    {512, 2, "icon_512x512@2x.png"}
};

static NSColor *rgb(CGFloat red, CGFloat green, CGFloat blue)
{
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:1.0];
}

static NSRect aligned_rect(CGFloat pixels, CGFloat x, CGFloat y,
                           CGFloat width, CGFloat height, NSInteger scale)
{
    return NSMakeRect(round(pixels*x), round(pixels*y),
                      MAX((CGFloat)scale, round(pixels*width)),
                      MAX((CGFloat)scale, round(pixels*height)));
}

static void rounded_fill(NSRect rect, CGFloat radius, NSColor *color)
{
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

static void draw_icon(CGFloat pixels, NSInteger scale)
{
    /* Fixed sRGB colours and an opaque graphite plate keep the drawing legible
     * on both light and dark desktops. ICNS itself has no appearance switching.
     * Outside the rounded plate remains transparent. */
    NSRect plate = aligned_rect(pixels, .06, .06, .88, .88, scale);
    CGFloat radius = pixels*.19;
    rounded_fill(plate, radius, rgb(.12, .14, .17));
    CGFloat border = MAX((CGFloat)scale*.5, pixels*.006);
    NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:
        NSInsetRect(plate, border*.5, border*.5)
        xRadius:radius-border*.5 yRadius:radius-border*.5];
    [edge setLineWidth:border];
    [rgb(.27, .30, .35) setStroke];
    [edge stroke];

    NSColor *white = rgb(.96, .97, .99);
    /* A closed, filled display with a straight stand. There is deliberately no
     * open outline or triangular sender shape from the AirPlay system glyph. */
    rounded_fill(aligned_rect(pixels, .46, .26, .08, .12, scale),
                 pixels*.012, white);
    rounded_fill(aligned_rect(pixels, .34, .23, .32, .05, scale),
                 MAX((CGFloat)scale*.5, pixels*.020), white);
    rounded_fill(aligned_rect(pixels, .22, .34, .56, .42, scale),
                 MAX((CGFloat)scale, pixels*.035), white);

    /* Three original blue reception bars inside the display. Each is at least
     * one logical pixel wide/high, including the 16-point representation. */
    NSColor *blue = rgb(.10, .43, .82);
    const CGFloat x[] = {.34, .46, .58};
    const CGFloat heights[] = {.09, .15, .22};
    for (NSUInteger index=0; index<3; ++index) {
        rounded_fill(aligned_rect(pixels, x[index], .42, .07, heights[index], scale),
                     pixels*.015, blue);
    }
}

static BOOL verify_png(NSString *path, NSInteger pixels)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    const unsigned char signature[] = {137,80,78,71,13,10,26,10};
    if (data.length < sizeof(signature) ||
        memcmp(data.bytes, signature, sizeof(signature)) != 0) return NO;
    NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithData:data];
    if (!image || image.pixelsWide != pixels || image.pixelsHigh != pixels ||
        !image.hasAlpha) return NO;

    /* Check the decoded file, not only the drawing context. These checks catch
     * empty, clipped, transparent or single-colour output; they are not visual
     * approval of an icon rendered on a Mac. */
    NSUInteger transparent=0, opaque=0, white=0, blue=0, graphite=0;
    NSColorSpace *sRGB = [NSColorSpace sRGBColorSpace];
    for (NSInteger y=0; y<pixels; ++y) {
        for (NSInteger x=0; x<pixels; ++x) {
            @autoreleasepool {
                NSColor *color = [[image colorAtX:x y:y] colorUsingColorSpace:sRGB];
                if (!color) return NO;
                CGFloat r=0, g=0, b=0, a=0;
                [color getRed:&r green:&g blue:&b alpha:&a];
                if (!isfinite(r) || !isfinite(g) || !isfinite(b) || !isfinite(a)) return NO;
                if (a < .02) ++transparent;
                if (a < .95) continue;
                ++opaque;
                if (r>.85 && g>.85 && b>.85) ++white;
                if (b>.60 && b>r*1.6 && g>r*1.2) ++blue;
                if (r<.30 && g<.35 && b<.40) ++graphite;
            }
        }
    }
    NSUInteger area=(NSUInteger)pixels*(NSUInteger)pixels;
    if (!transparent || opaque<area/2 || white<area/12 || !blue || graphite<area/4)
        return NO;
    fprintf(stdout, "AIRPLAY_ICON PNG_OK name=%s pixels=%ld white=%lu blue=%lu graphite=%lu\n",
        path.lastPathComponent.UTF8String, (long)pixels,
        (unsigned long)white, (unsigned long)blue, (unsigned long)graphite);
    return YES;
}

static BOOL write_representation(NSString *directory, IconRepresentation spec)
{
    NSInteger pixels=spec.points*spec.scale;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0
        bytesPerRow:pixels*4 bitsPerPixel:32];
    if (!bitmap || !bitmap.bitmapData) return NO;
    memset(bitmap.bitmapData, 0, (size_t)bitmap.bytesPerRow*(size_t)pixels);
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (!context) return NO;
    NSGraphicsContext *previous = [NSGraphicsContext currentContext];
    @try {
        [NSGraphicsContext setCurrentContext:context];
        CGContextSetShouldAntialias(context.CGContext, true);
        draw_icon((CGFloat)pixels, spec.scale);
        [context flushGraphics];
    } @finally {
        [NSGraphicsContext setCurrentContext:previous];
    }
    /* Drawing above is in pixel coordinates. Set the logical size afterwards
     * so @2x files retain their intended resolution metadata. */
    [bitmap setSize:NSMakeSize(spec.points,spec.points)];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithUTF8String:spec.name]];
    NSError *error=nil;
    if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "AIRPLAY_ICON cannot write PNG: %s\n",
            error.localizedDescription.UTF8String ?: "no bitmap data");
        return NO;
    }
    return verify_png(path,pixels);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: render-icon NEW_DIRECTORY.iconset\n");
            return 64;
        }
        @try {
            NSString *directory = [NSString stringWithUTF8String:argv[1]];
            if (!directory || ![directory.pathExtension isEqualToString:@"iconset"] ||
                [[NSFileManager defaultManager] fileExistsAtPath:directory]) {
                fprintf(stderr, "AIRPLAY_ICON expected a new .iconset directory\n");
                return 73;
            }
            NSError *error=nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                    withIntermediateDirectories:NO
                    attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
                fprintf(stderr, "AIRPLAY_ICON cannot create iconset: %s\n",
                    error.localizedDescription.UTF8String ?: "unknown error");
                return 73;
            }
            for (NSUInteger index=0; index<sizeof(representations)/sizeof(representations[0]); ++index) {
                @autoreleasepool {
                    if (!write_representation(directory,representations[index])) {
                        fprintf(stderr, "AIRPLAY_ICON representation failed: %s\n", representations[index].name);
                        return 74;
                    }
                }
            }
            fprintf(stdout, "AIRPLAY_ICON ICONSET_OK representations=10 design=original-closed-display\n");
            return 0;
        } @catch (NSException *exception) {
            fprintf(stderr, "AIRPLAY_ICON exception: %s: %s\n",
                exception.name.UTF8String, exception.reason.UTF8String ?: "");
            return 70;
        }
    }
}
