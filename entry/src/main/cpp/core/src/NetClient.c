#include "NetClient.h"
#include "States.h"
#include "utils/PlatformUtils.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

#define MAX_RESPONSE (2 * 1024 * 1024)
static char school_id[8], domain[16], area[8];
static bool has_chunked(const char* value)
{
    for (const char* p=value; *p; p++) if (!strncasecmp(p,"chunked",7)) return true;
    return false;
}

/* MD5 is required by the campus protocol's CDC-Checksum header. */
static uint32_t rol(uint32_t x, unsigned n) { return (x << n) | (x >> (32 - n)); }
static void md5(const unsigned char* input, size_t length, char out[33])
{
    static const uint32_t k[64] = {
        0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
        0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
        0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
        0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
        0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
        0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
        0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
        0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
    };
    static const uint8_t shifts[64] = {
        7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
        5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
        4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
        6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
    };
    size_t padded = ((length + 8) / 64 + 1) * 64;
    unsigned char* msg = calloc(1, padded);
    if (!msg) { out[0] = 0; return; }
    memcpy(msg, input, length);
    msg[length] = 0x80;
    uint64_t bits = (uint64_t)length * 8;
    for (int i = 0; i < 8; i++) msg[padded - 8 + i] = (unsigned char)(bits >> (8 * i));
    uint32_t state[4] = {0x67452301,0xefcdab89,0x98badcfe,0x10325476};
    for (size_t offset = 0; offset < padded; offset += 64) {
        uint32_t words[16];
        for (int i = 0; i < 16; i++) {
            const unsigned char* p = msg + offset + i * 4;
            words[i] = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
        }
        uint32_t a=state[0], b=state[1], c=state[2], d=state[3];
        for (uint32_t i = 0; i < 64; i++) {
            uint32_t f, g;
            if (i < 16) { f=(b & c) | (~b & d); g=i; }
            else if (i < 32) { f=(d & b) | (~d & c); g=(5*i+1)%16; }
            else if (i < 48) { f=b ^ c ^ d; g=(3*i+5)%16; }
            else { f=c ^ (b | ~d); g=(7*i)%16; }
            uint32_t next=d;
            d=c; c=b; b=b+rol(a+f+k[i]+words[g],shifts[i]); a=next;
        }
        state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
    }
    free(msg);
    for (int i=0; i<4; i++) for (int j=0; j<4; j++)
        snprintf(out + (i*4+j)*2, 3, "%02x", (state[i] >> (j*8)) & 0xff);
}

typedef struct { char host[256]; char path[2048]; unsigned port; } parsed_url_t;
static bool parse_url(const char* url, parsed_url_t* parsed)
{
    if (!url || strncmp(url, "http://", 7) != 0) return false;
    const char* host = url + 7;
    const char* end = host;
    while (*end && *end != '/' && *end != '?' && *end != '#') end++;
    const char* colon = memchr(host, ':', (size_t)(end-host));
    size_t host_len = (size_t)((colon ? colon : end) - host);
    if (!host_len || host_len >= sizeof(parsed->host)) return false;
    memcpy(parsed->host, host, host_len); parsed->host[host_len] = 0;
    parsed->port = colon ? (unsigned)atoi(colon + 1) : 80;
    if (!parsed->port || parsed->port > 65535) return false;
    snprintf(parsed->path, sizeof(parsed->path), "%s%s", *end == '/' ? "" : "/", *end ? end : "");
    if (!parsed->path[0]) strcpy(parsed->path, "/");
    return true;
}

static int connect_host(const parsed_url_t* url)
{
    struct addrinfo hints = {0}, *list = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    char port[8]; snprintf(port, sizeof(port), "%u", url->port);
    if (getaddrinfo(url->host, port, &hints, &list) != 0) return -1;
    int fd = -1;
    for (struct addrinfo* it = list; it; it = it->ai_next) {
        fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd < 0) continue;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, it->ai_addr, it->ai_addrlen);
        if (rc < 0 && errno == EINPROGRESS) {
            fd_set set; FD_ZERO(&set); FD_SET(fd, &set);
            struct timeval timeout = {3,0};
            rc = select(fd+1, NULL, &set, NULL, &timeout);
            if (rc > 0) { int error=0; socklen_t size=sizeof(error); getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size); rc = error ? -1 : 0; }
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);
            struct timeval timeout = {5,0};
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            break;
        }
        close(fd); fd=-1;
    }
    freeaddrinfo(list);
    return fd;
}

static void capture_header(const char* key, const char* value, const char* url)
{
    if (!strcasecmp(key,"schoolid")) snprintf(school_id,sizeof(school_id),"%s",value);
    else if (!strcasecmp(key,"domain")) snprintf(domain,sizeof(domain),"%s",value);
    else if (!strcasecmp(key,"area")) snprintf(area,sizeof(area),"%s",value);
    else if (!strcasecmp(key,"location") && tl_thread_idx >= 0 && !g_prog_status[tl_thread_idx].last_location_lock) {
        char resolved[LAST_LOCATION_LEN * 2];
        if (!strncasecmp(value,"http://",7)) snprintf(resolved,sizeof(resolved),"%s",value);
        else if (value[0]=='/') {
            parsed_url_t p;
            if (!parse_url(url,&p)) return;
            snprintf(resolved,sizeof(resolved),"http://%s:%u%s",p.host,p.port,value);
        } else {
            const char* slash = strrchr(url,'/');
            size_t prefix = slash && slash >= url+7 ? (size_t)(slash-url+1) : strlen(url);
            if (prefix + strlen(value) >= sizeof(resolved)) return;
            memcpy(resolved,url,prefix); strcpy(resolved+prefix,value);
        }
        snprintf(g_prog_status[tl_thread_idx].last_location,LAST_LOCATION_LEN*2,"%s",resolved);
    }
}

static bool decode_chunked(const char* data, size_t length, char** output, size_t* output_length)
{
    char* result = malloc(length+1); if (!result) return false;
    size_t in=0,out=0;
    while (in < length) {
        char* end=NULL; unsigned long chunk=strtoul(data+in,&end,16);
        if (end == data+in || end >= data+length) break;
        in = (size_t)(end-data);
        while (in < length && data[in] != '\n') in++;
        if (in < length) in++;
        if (chunk == 0) { result[out]=0; *output=result; *output_length=out; return true; }
        if (chunk > length-in) break;
        memcpy(result+out,data+in,chunk); out+=chunk; in+=chunk;
        if (in < length && data[in]=='\r') in++;
        if (in < length && data[in]=='\n') in++;
    }
    free(result); return false;
}

static curl_resp_t request(const char* url, const char* body)
{
    curl_resp_t response = {0}; response.status=STATUS_ERROR; response.curl_code=1;
    parsed_url_t parsed;
    if (!parse_url(url,&parsed)) return response;
    int fd=connect_host(&parsed); if (fd<0) return response;
    char checksum[33]={0};
    if (body) md5((const unsigned char*)body,strlen(body),checksum);
    const char* ua = tl_thread_idx >= 0 ? g_prog_status[tl_thread_idx].login_cfg.user_agent : "CCTP/android11_64/2104";
    const char* cid = tl_thread_idx >= 0 ? g_prog_status[tl_thread_idx].auth_cfg.client_id : "";
    const char* aid = tl_thread_idx >= 0 ? g_prog_status[tl_thread_idx].auth_cfg.algo_id : "";
    char header[4096];
    char host_header[272];
    if (parsed.port == 80) snprintf(host_header,sizeof(host_header),"%s",parsed.host);
    else snprintf(host_header,sizeof(host_header),"%s:%u",parsed.host,parsed.port);
    int header_len = snprintf(header,sizeof(header),
        "%s %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nAccept: text/html,text/xml,application/xhtml+xml,application/x-javascript,*/*\r\nClient-ID: %s\r\nConnection: close\r\n%s",
        body ? "POST" : "GET",parsed.path,host_header,ua,cid,
        body ? "Content-Type: application/x-www-form-urlencoded\r\n" : "");
    if (body) header_len += snprintf(header+header_len,sizeof(header)-(size_t)header_len,
        "CDC-Checksum: %s\r\nAlgo-ID: %s\r\nCDC-SchoolId: %s\r\nCDC-Domain: %s\r\nCDC-Area: %s\r\nContent-Length: %zu\r\n",
        checksum,aid,school_id,domain,area,strlen(body));
    header_len += snprintf(header+header_len,sizeof(header)-(size_t)header_len,"\r\n");
    if (header_len <= 0 || (size_t)header_len >= sizeof(header)) { close(fd); return response; }
    size_t sent=0, total=(size_t)header_len;
    while (sent<total) { ssize_t n=send(fd,header+sent,total-sent,MSG_NOSIGNAL); if (n<=0) { close(fd); return response; } sent+=(size_t)n; }
    if (body) { sent=0; total=strlen(body); while(sent<total) { ssize_t n=send(fd,body+sent,total-sent,MSG_NOSIGNAL); if(n<=0) { close(fd); return response; } sent+=(size_t)n; } }
    char* raw=NULL; size_t used=0;
    for (;;) {
        if (used >= MAX_RESPONSE) break;
        char* next=realloc(raw,used+8193); if(!next) break;
        raw=next; ssize_t n=recv(fd,raw+used,8192,0);
        if(n==0) { response.curl_code=CURLE_OK; break; }
        if(n<0) break;
        used+=(size_t)n;
    }
    close(fd);
    if (!raw || used<12) { free(raw); return response; }
    raw[used]=0;
    char* sep=strstr(raw,"\r\n\r\n"); if(!sep) { free(raw); return response; }
    size_t head_len=(size_t)(sep-raw); size_t body_offset=head_len+4;
    long code=0; sscanf(raw,"HTTP/%*d.%*d %ld",&code);
    if (response.curl_code == CURLE_OK) response.http_code=code;
    bool chunked=false;
    char* line=strstr(raw,"\r\n");
    while (line && line < sep) {
        line+=2; if (line>=sep) break;
        char* next=strstr(line,"\r\n"); if (!next || next>sep) break;
        char* colon=memchr(line,':',(size_t)(next-line));
        if(colon) {
            char key[64],value[LAST_LOCATION_LEN*2];
            size_t kn=(size_t)(colon-line),vn=(size_t)(next-colon-1);
            if(kn<sizeof(key) && vn<sizeof(value)) {
                memcpy(key,line,kn); key[kn]=0;
                const char* v=colon+1; while(v<next && isspace((unsigned char)*v)) { v++; vn--; }
                memcpy(value,v,vn); value[vn]=0;
                capture_header(key,value,url);
                if(!strcasecmp(key,"transfer-encoding") && has_chunked(value)) chunked=true;
            }
        }
        line=next;
    }
    size_t length=used-body_offset;
    if (chunked) {
        if(!decode_chunked(raw+body_offset,length,&response.body_data,&response.body_size)) response.curl_code=1;
    } else {
        response.body_data=malloc(length+1);
        if(response.body_data) { memcpy(response.body_data,raw+body_offset,length); response.body_data[length]=0; response.body_size=length; }
    }
    free(raw);
    response.status = response.curl_code==CURLE_OK && code>=200 && code<400 ? STATUS_OK : STATUS_ERROR;
    return response;
}

curl_resp_t get(const char* url, bool connect_only) { (void)connect_only; return request(url,NULL); }
curl_resp_t post(const char* url, const char* data) { return request(url,data ? data : ""); }

char* extract_url_param(const char* url, const char* key)
{
    if(!url || !key) return NULL;
    size_t len=strlen(key); const char* p=strchr(url,'?'); if(!p) return NULL; p++;
    while(*p) {
        if(!strncmp(p,key,len) && p[len]=='=') {
            const char* start=p+len+1; const char* end=strchr(start,'&'); if(!end) end=start+strlen(start);
            size_t n=(size_t)(end-start); char* value=malloc(n+1); if(!value) return NULL;
            memcpy(value,start,n); value[n]=0; return value;
        }
        p=strchr(p,'&'); if(!p) break; p++;
    }
    return NULL;
}

network_status_t check_network_status(bool connect_only)
{
    (void)connect_only;
    const char* urls[]={"http://connect.rom.miui.com/generate_204","http://1.1.1.1","http://14.146.227.141:7001","http://14.146.227.142:7001"};
    for(size_t i=0;i<4;i++) {
        curl_resp_t r=get(urls[i],false);
        network_status_t result=STATUS_ERROR;
        if(r.http_code==302 || r.http_code==307) result=STATUS_NEED_AUTH;
        else if(i<2 && (r.http_code==204 || r.http_code==301)) result=STATUS_OK;
        free(r.body_data);
        if(result!=STATUS_ERROR) return result;
    }
    return STATUS_ERROR;
}

bool get_last_location(void) { return g_prog_status && g_prog_status[0].last_location[0]!=0; }
