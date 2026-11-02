#ifndef TARGET_PROCESSING_H
#define TARGET_PROCESSING_H
#include <stdint.h>
#define TARGET_CAPACITY 8u
typedef struct {
    uint32_t area;
    uint16_t xmin,xmax,ymin,ymax;
    uint8_t label,id,shape,geometry_error;
} Target;
typedef struct {
    uint32_t sequence,frame_id,dropped;
    uint16_t total;
    uint8_t count,error;
    Target items[TARGET_CAPACITY];
} TargetSnapshot;
typedef struct {
    Target slots[TARGET_CAPACITY];
    uint8_t missed[TARGET_CAPACITY],active,next_id;
} TargetTracker;
void target_tracker_init(TargetTracker *tracker);
void target_tracker_forget(TargetTracker *tracker);
void target_classify(Target *target);
void target_process(TargetTracker *tracker,const TargetSnapshot *input,TargetSnapshot *output);
uint32_t target_pack_low(const Target *target);
uint32_t target_pack_high(const Target *target);
#endif
