#import <Foundation/Foundation.h>
#include <SpatialAudioCore/SpatialAudioCore.h>
#include <stdio.h>

int other_rust_value(int value);
int other_rust_catches(void);
int host_cxx_catches(void);

static int32_t pcm(void *context, const float *samples, uint32_t frames,
                   uint32_t rate, uint32_t channels) {
    (void)samples; (void)frames; (void)rate; (void)channels;
    *(int *)context += 1;
    return 0;
}

static int core_calls(void) {
    for (uint32_t codec = 1; codec <= 2; ++codec) {
        SABHandle *handle = sab_create(codec, 12);
        if (!handle) return 0;
        int callbacks = 0;
        sab_set_dialogue_normalisation(handle, 1);
        int accepted = sab_push(handle, NULL, 0, 0, pcm, &callbacks) == 0;
        // A defined API error exercises owned error storage and terminal session behavior.
        int rejected = sab_push(handle, NULL, 1, 0, pcm, &callbacks) == -1;
        char error[128] = {0};
        size_t required = sab_error(handle, error, sizeof(error));
        int terminal = sab_push(handle, NULL, 0, 0, pcm, &callbacks) == -1;
        sab_destroy(handle);
        if (!(accepted && rejected && terminal && required > 1 && error[0] && callbacks == 0))
            return 0;
    }
    return 1;
}

static int objc_catches(void) {
    int caught = 0, finalized = 0;
    @try {
        @try {
            @throw [NSException exceptionWithName:@"MixedHost" reason:@"deliberate" userInfo:nil];
        } @finally {
            finalized = 1;
        }
    } @catch (NSException *exception) {
        caught = [exception.name isEqualToString:@"MixedHost"];
    }
    return caught && finalized;
}

int main(void) {
    @autoreleasepool {
        int before = core_calls();
        int normal = other_rust_value(41) == 42;
        int rust = other_rust_catches();
        int objc = objc_catches();
        int cxx = host_cxx_catches();
        int after = core_calls();
        printf("SAB before=%d after=%d; Rust normal=%d catch/drop=%d; ObjC catch/finally=%d; C++ catch/drop=%d\n",
               before, after, normal, rust, objc, cxx);
        return before && after && normal && rust && objc && cxx ? 0 : 1;
    }
}
