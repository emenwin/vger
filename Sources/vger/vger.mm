//  Copyright © 2021 Audulus LLC. All rights reserved.

#import "vger.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#else
#import <UIKit/UIKit.h>
#endif

#import "vgerRenderer.h"
#import "vgerTextureManager.h"
#import "vgerGlyphCache.h"
#include <vector>
#include <unordered_map>
#include <string>

using namespace simd;
#import "sdf.h"

/// For caching the layout of strings.
struct TextLayoutInfo {
    /// The frame in which the string was last rendered. If not the current frame,
    /// then the string is pruned from the cache.
    uint64_t lastFrame = 0;

    /// Prims are copied to output.
    std::vector<vgerPrim> prims;
};

/// Main state object. This is not ObjC to avoid call overhead for each prim.
struct vger {

    id<MTLDevice> device;
    vgerRenderer* renderer;

    /// Transform matrix stack.
    std::vector<matrix_float3x3> txStack;

    /// We cycle through three prim buffers for streaming.
    id<MTLBuffer> prims[3];

    /// The prim buffer we're currently using.
    int curPrims = 0;

    /// Pointer to the next prim to be saved in the buffer.
    vgerPrim* p;

    /// Number of prims we've saved in the buffer.
    int primCount = 0;

    /// Prim buffer capacity.
    int maxPrims = 16384;

    /// Atlas for finding glyph images.
    vgerGlyphCache* glyphCache;

    /// Size of rendering window (for conversion from pixel to NDC)
    float2 windowSize;

    /// Glyph scratch space (avoid malloc).
    std::vector<CGGlyph> glyphs;

    /// Cache of text layout by strings.
    std::unordered_map<std::string, TextLayoutInfo > textCache;

    /// Determines whether we prune cached text.
    uint64_t currentFrame = 1;

    /// User-created textures.
    NSMutableArray< id<MTLTexture> >* textures;

    /// We can't insert nil into textures, so use a tiny texture instead.
    id<MTLTexture> nullTexture;

    vger() {
        device = MTLCreateSystemDefaultDevice();
        renderer = [[vgerRenderer alloc] initWithDevice:device];
        glyphCache = [[vgerGlyphCache alloc] initWithDevice:device];
        for(int i=0;i<3;++i) {
            prims[i] = [device newBufferWithLength:maxPrims * sizeof(vgerPrim)
                                           options:MTLResourceStorageModeShared];
        }
        txStack.push_back(matrix_identity_float3x3);

        auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        nullTexture = [device newTextureWithDescriptor:desc];

        textures = [NSMutableArray new];

        assert(device.argumentBuffersSupport == MTLArgumentBuffersTier2);
    }
};

vger* vgerNew() {
    return new vger;
}

void vgerDelete(vger* vg) {
    delete vg;
}

void vgerBegin(vger* vg, float windowWidth, float windowHeight, float devicePxRatio) {
    vg->curPrims = (vg->curPrims+1)%3;
    vg->p = (vgerPrim*) vg->prims[vg->curPrims].contents;
    vg->primCount = 0;
    vg->windowSize = {windowWidth, windowHeight};
}

int  vgerAddTexture(vger* vg, const uint8_t* data, int width, int height) {
    assert(data);

    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX
    desc.storageMode = MTLStorageModeManaged;
#else
    desc.storageMode = MTLStorageModeShared;
#endif
    auto tex = [vg->device newTextureWithDescriptor:desc];
    assert(tex);

    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:data bytesPerRow:width*sizeof(uint32_t)];

    return vgerAddMTLTexture(vg, tex);
}

int vgerAddMTLTexture(vger* vg, id<MTLTexture> tex) {
    assert(tex);
    [vg->textures addObject:tex];
    return vg->textures.count-1;
}

void vgerDeleteTexture(vger* vg, int texID) {
    assert(vg);
    [vg->textures setObject:vg->nullTexture atIndexedSubscript:texID];
}


vector_int2 vgerTextureSize(vger* vg, int texID) {
    auto tex = [vg->textures objectAtIndex:texID];
    return {int(tex.width), int(tex.height)};
}

void vgerRender(vger* vg, const vgerPrim* prim) {

    if(prim->type == vgerBezier or prim->type == vgerCurve) {

        auto bounds = sdPrimBounds(*prim).inset(-1);

        float2 tiles = {2,2};
        auto tile_size = bounds.size() / tiles;

        for(float y=0;y<tiles.y;++y) {
            for(float x=0;x<tiles.x;++x) {

                float2 c = bounds.min + tile_size * float2{x+.5f, y+.5f};
                vgerPrim p = *prim;
                p.texcoords[0] = bounds.min + tile_size * float2{x,y};
                p.texcoords[1] = bounds.min + tile_size * float2{x+1,y};
                p.texcoords[2] = bounds.min + tile_size * float2{x,y+1};
                p.texcoords[3] = bounds.min + tile_size * float2{x+1,y+1};

                for(int i=0;i<4;++i) {
                    p.verts[i] = p.texcoords[i];
                }
                p.xform = vg->txStack.back();

                if(vg->primCount < vg->maxPrims) {
                    *vg->p = p;

                    vg->p++;
                    vg->primCount++;
                }

            }
        }

    } else {

        if(vg->primCount < vg->maxPrims) {
            *vg->p = *prim;

            auto bounds = sdPrimBounds(*prim).inset(-1);
            vg->p->texcoords[0] = bounds.min;
            vg->p->texcoords[1] = float2{bounds.max.x, bounds.min.y};
            vg->p->texcoords[2] = float2{bounds.min.x, bounds.max.y};
            vg->p->texcoords[3] = bounds.max;

            for(int i=0;i<4;++i) {
                vg->p->verts[i] = vg->p->texcoords[i];
            }

            vg->p->xform = vg->txStack.back();

            vg->p++;
            vg->primCount++;
        }

    }

}

void vgerRenderText(vger* vg, const char* str, float4 color) {

    auto paint = vgerColorPaint(color);

    // Do we already have text in the cache?
    auto iter = vg->textCache.find(std::string(str));
    if(iter != vg->textCache.end()) {
        // Copy prims to output.
        auto& info = iter->second;
        info.lastFrame = vg->currentFrame;
        for(auto& prim : info.prims) {
            if(vg->primCount < vg->maxPrims) {
                *vg->p = prim;
                vg->p->xform = vg->txStack.back();
                vg->p++;
                vg->primCount++;
            }
        }
        return;
    }

    // Text cache miss, do more expensive typesetting.

    CFRange entire = CFRangeMake(0, 0);

    auto attributes = @{ NSFontAttributeName : (__bridge id)[vg->glyphCache getFont] };
    auto string = [NSString stringWithUTF8String:str];
    auto attrString = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    auto typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attrString);
    auto line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, attrString.length));

    auto& textInfo = vg->textCache[str];
    textInfo.lastFrame = vg->currentFrame;

    NSArray* runs = (__bridge id) CTLineGetGlyphRuns(line);
    for(id r in runs) {
        CTRunRef run = (__bridge CTRunRef)r;
        size_t glyphCount = CTRunGetGlyphCount(run);

        vg->glyphs.resize(glyphCount);
        CTRunGetGlyphs(run, entire, vg->glyphs.data());

        for(int i=0;i<glyphCount;++i) {

            auto info = [vg->glyphCache getGlyph:vg->glyphs[i] size:12];
            if(info.regionIndex != -1) {

                CGRect r = CTRunGetImageBounds(run, nil, CFRangeMake(i, 1));
                float2 p = {float(r.origin.x), float(r.origin.y)};
                float2 sz = {float(r.size.width), float(r.size.height)};

                float2 a = p-1, b = p+sz+2;

                vgerPrim prim = {
                    .type = vgerGlyph,
                    .cvs = {a, b},
                    .width = 0.01,
                    .radius = 0,
                    .paint = paint
                };

                prim.paint.image = info.regionIndex;

                prim.verts[0] = a;
                prim.verts[1] = float2{b.x, a.y};
                prim.verts[2] = float2{a.x, b.y};
                prim.verts[3] = b;
                prim.xform = vg->txStack.back();

                auto bounds = info.glyphBounds;
                float w = info.glyphBounds.size.width+2;
                float h = info.glyphBounds.size.height+2;

                float originY = info.textureHeight-GLYPH_MARGIN;

                prim.texcoords[0] = float2{GLYPH_MARGIN-1,   originY+1};
                prim.texcoords[1] = float2{GLYPH_MARGIN+w+1, originY+1};
                prim.texcoords[2] = float2{GLYPH_MARGIN-1,   originY-h-1};
                prim.texcoords[3] = float2{GLYPH_MARGIN+w+1, originY-h-1};

                textInfo.prims.push_back(prim);

                if(vg->primCount < vg->maxPrims) {
                    *vg->p = prim;
                    vg->p++;
                    vg->primCount++;
                }
            }
        }
    }

    CFRelease(typesetter);
    CFRelease(line);

}

void vgerTextBounds(vger* vg, const char* str, float2* min, float2* max) {

    CFRange entire = CFRangeMake(0, 0);

    auto attributes = @{ NSFontAttributeName : (__bridge id)[vg->glyphCache getFont] };
    auto string = [NSString stringWithUTF8String:str];
    auto attrString = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    auto typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attrString);
    auto line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, attrString.length));

    auto bounds = CTLineGetImageBounds(line, nil);
    min->x = bounds.origin.x;
    min->y = bounds.origin.y;
    max->x = bounds.origin.x + bounds.size.width;
    max->y = bounds.origin.x + bounds.size.height;

}

void vgerEncode(vger* vg, id<MTLCommandBuffer> buf, MTLRenderPassDescriptor* pass) {

    // Prune the text cache.
    for(auto it = begin(vg->textCache); it != end(vg->textCache);) {
        if (it->second.lastFrame != vg->currentFrame) {
            it = vg->textCache.erase(it);
        } else {
            ++it;
        }
    }
    
    [vg->glyphCache update:buf];

    auto glyphRects = [vg->glyphCache getRects];
    auto primp = (vgerPrim*) vg->prims[vg->curPrims].contents;
    for(int i=0;i<vg->primCount;++i) {
        auto& prim = primp[i];
        if(prim.type == vgerGlyph) {
            auto r = glyphRects[prim.paint.image-1];
            for(int i=0;i<4;++i) {
                prim.texcoords[i] += float2{float(r.x), float(r.y)};
            }
        }
    }

    [vg->renderer encodeTo:buf
                      pass:pass
                     prims:vg->prims[vg->curPrims]
                     count:vg->primCount
                  textures:vg->textures
              glyphTexture:[vg->glyphCache getAltas]
                windowSize:vg->windowSize];

    vg->currentFrame++;
}

void vgerTranslate(vger* vg, vector_float2 t) {
    auto M = matrix_identity_float3x3;
    M.columns[2] = vector3(t, 1);

    auto& A = vg->txStack.back();
    A = matrix_multiply(A, M);
}

/// Scales current coordinate system.
void vgerScale(vger* vg, vector_float2 s) {
    auto M = matrix_identity_float3x3;
    M.columns[0].x = s.x;
    M.columns[1].y = s.y;

    auto& A = vg->txStack.back();
    A = matrix_multiply(A, M);
}

/// Transforms a point according to the current transformation.
vector_float2 vgerTransform(vger* vg, vector_float2 p) {
    auto& M = vg->txStack.back();
    auto q = matrix_multiply(M, float3{p.x,p.y,1.0});
    return {q.x/q.z, q.y/q.z};
}

simd_float3x2 vgerCurrentTransform(vger* vg) {
    auto& M = vg->txStack.back();
    return {
        M.columns[0].xy, M.columns[1].xy, M.columns[2].xy
    };
}

void vgerSave(vger* vg) {
    vg->txStack.push_back(vg->txStack.back());
}

void vgerRestore(vger* vg) {
    vg->txStack.pop_back();
    assert(!vg->txStack.empty());
}

id<MTLTexture> vgerGetGlyphAtlas(vger* vg) {
    return [vg->glyphCache getAltas];
}

vgerPaint vgerColorPaint(vector_float4 color) {

    vgerPaint p;
    p.xform = matrix_identity_float3x3;
    p.innerColor = color;
    p.outerColor = color;
    p.image = -1;

    return p;
}

vgerPaint vgerLinearGradient(vector_float2 start, vector_float2 end,
                             vector_float4 innerColor, vector_float4 outerColor) {

    vgerPaint p;

    // Calculate transform aligned to the line
    vector_float2 d = end - start;
    if(simd_length(d) < 0.0001f) {
        d = float2{0,1};
    }

    p.xform = simd_inverse(matrix_float3x3{
        float3{d.x, d.y, 0},
        float3{-d.y, d.x, 0},
        float3{start.x, start.y, 1}
    });

    p.innerColor = innerColor;
    p.outerColor = outerColor;
    p.image = -1;

    return p;

}

vgerPaint vgerImagePattern(vector_float2 origin, vector_float2 size, float angle,
                           int image, float alpha) {

    vgerPaint p;
    p.image = image;

    matrix_float3x3 R = {
        float3{ cosf(angle), sinf(angle), 0 },
        float3{ -sinf(angle), cosf(angle), 0 },
        float3{ -origin.x, -origin.y, 1}
    };

    matrix_float3x3 S = {
        float3{ 1/size.x, 0, 0 },
        float3{ 0, 1/size.y, 0},
        float3{ 0, 0, 1}
    };

    p.xform = S;

    p.innerColor = p.outerColor = float4{1,1,1,alpha};

    return p;
}
