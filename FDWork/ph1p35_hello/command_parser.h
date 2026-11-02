#ifndef COMMAND_PARSER_H
#define COMMAND_PARSER_H
#include <stdint.h>
#include <string.h>
enum command_kind { CMD_BAD, CMD_SET, CMD_FPGA, CMD_STATUS, CMD_HELP, CMD_TARGETS };
/* Strict bounded decimal parsing: no sign, overflow, missing or extra tokens. */
static enum command_kind parse_command(const char *line, uint32_t *packed) {
    while (*line==' ' || *line=='\t') ++line;
    size_t len=strlen(line);
    while (len && (line[len-1]==' ' || line[len-1]=='\t')) --len;
    if (len==4 && !strncmp(line,"fpga",4)) return CMD_FPGA;
    if (len==6 && !strncmp(line,"status",6)) return CMD_STATUS;
    if (len==4 && !strncmp(line,"help",4)) return CMD_HELP;
    if (len==7 && !strncmp(line,"targets",7)) return CMD_TARGETS;
    if (len<4 || strncmp(line,"set",3) || (line[3]!=' ' && line[3]!='\t')) return CMD_BAD;
    const char *p=line+3,*end=line+len;
    uint32_t value=0;
    for (unsigned i=0;i<3;++i) {
        if (p==end || (*p!=' ' && *p!='\t')) return CMD_BAD;
        while (p<end && (*p==' ' || *p=='\t')) ++p;
        if (p==end || *p<'0' || *p>'9') return CMD_BAD;
        unsigned n=0;
        do { n=n*10u+(unsigned)(*p++-'0'); if(n>255) return CMD_BAD; }
        while (p<end && *p>='0' && *p<='9');
        value=(value<<8)|n;
    }
    if (p!=end) return CMD_BAD;
    *packed=value;
    return CMD_SET;
}
#endif
