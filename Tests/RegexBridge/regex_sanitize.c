#include "SwiftDiffsRegex.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
int main(void) {
    const char *patterns[] = {"a{1,3}", "(a+)(b)?", "(?<=a)b", "(?<x>a)\\k<x>", "(?:a|ab)*b", "(a?)*", "[a-z]+", "[", "\\d+"};
    const uint16_t text[] = {'a','a','a','b',0xD83D,0xDE00,'1','2',0};
    for (int run=0;run<100;run++) for (int p=0;p<9;p++) {
        char error[256]={0}; size_t length=0; while(patterns[p][length])length++;
        SDRegex *regex=sd_regex_create(patterns[p],length,1,1,error,256);
        if(!regex) {assert(p==7);continue;}
        int count=sd_regex_capture_count(regex);int32_t *ranges=calloc((size_t)count*2,sizeof(int32_t));
        for(int start=0;start<=8;start++) {int result=sd_regex_exec(regex,text,8,start,ranges,count*2,1000);assert(result>=0);if(result){assert(ranges[0]>=start);assert(ranges[1]<=8);}}
        free(ranges);sd_regex_destroy(regex);
    }
    {
        char error[256]={0};
        SDRegex *regex=sd_regex_create("(a+)+$",6,0,1,error,256);assert(regex);
        uint16_t slow[40];for(int i=0;i<39;i++)slow[i]='a';slow[39]='!';
        int32_t ranges[4];assert(sd_regex_exec(regex,slow,40,0,ranges,4,1)==-2);
        sd_regex_destroy(regex);
    }
    puts("Native regex bridge: AddressSanitizer and UndefinedBehaviorSanitizer passed");
}
