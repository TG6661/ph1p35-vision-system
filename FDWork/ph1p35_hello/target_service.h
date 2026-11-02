#ifndef TARGET_SERVICE_H
#define TARGET_SERVICE_H
#include "target_processing.h"
typedef struct {
    TargetTracker tracker;
    TargetSnapshot input,output,last;
    uint32_t last_poll,start,last_sequence,accepted_before,last_ms,resyncs,rejects;
    uint8_t phase,word,have_sequence,have_last,last_input_count;
} TargetService;
void target_service_init(TargetService *service,uint32_t now);
void target_service_poll(TargetService *service,uint32_t now);
#endif
