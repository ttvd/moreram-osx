#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>

#import <libkern/OSAtomic.h>
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

typedef struct moreram_osx_node_s moreram_osx_node_t;
struct moreram_osx_node_s
{
    id<MTLBuffer> buffer;
    size_t size;
    void* address;

    moreram_osx_node_t* prev;
    moreram_osx_node_t* next;
};

typedef struct moreram_osx_context_s moreram_osx_context_t;
struct moreram_osx_context_s
{
    id<MTLDevice> device;
    NSLock* lock;

    int32_t instance_count;

    moreram_osx_node_t* head;
    moreram_osx_node_t* tail;

    void* (*libc_malloc_func)(size_t);
    void* (*libc_realloc_func)(void*, size_t);
    void* (*libc_calloc_func)(size_t, size_t);
    void (*libc_free_func)(void*);

};

static moreram_osx_context_t g_moreram_osx_context;

__attribute__((constructor))
static
void
moreram_osx_initialize()
{
    if(!OSAtomicCompareAndSwap32(0, 1, &g_moreram_osx_context.instance_count))
    {
        // Avoid multiple initialization.
        OSAtomicIncrement32(&g_moreram_osx_context.instance_count);
        return;
    }

    // Retrieve standard mem func pointers.
    g_moreram_osx_context.libc_malloc_func = dlsym(RTLD_NEXT, "malloc");
    g_moreram_osx_context.libc_realloc_func = dlsym(RTLD_NEXT, "realloc");
    g_moreram_osx_context.libc_calloc_func = dlsym(RTLD_NEXT, "calloc");
    g_moreram_osx_context.libc_free_func = dlsym(RTLD_NEXT, "free");

    // Create lock.
    g_moreram_osx_context.lock = [[NSLock alloc] init];
    if(!g_moreram_osx_context.lock)
    {
        // Failed allocating a lock.
        abort();
    }

    // Create device.
    g_moreram_osx_context.device = MTLCreateSystemDefaultDevice();
    if(!g_moreram_osx_context.device)
    {
        // Unable to create device, Metal is not available.
        [g_moreram_osx_context.lock release];
        abort();
    }

    g_moreram_osx_context.head = 0;
    g_moreram_osx_context.tail = 0;
}

__attribute__((destructor))
static
void
moreram_osx_finalize()
{
    if(!OSAtomicCompareAndSwap32(1, 0, &g_moreram_osx_context.instance_count))
    {
        // Avoid multiple finalization.
        OSAtomicDecrement32(&g_moreram_osx_context.instance_count);
        return;
    }

    // Reset standard mem func pointers.
    g_moreram_osx_context.libc_malloc_func = 0;
    g_moreram_osx_context.libc_realloc_func = 0;
    g_moreram_osx_context.libc_calloc_func = 0;
    g_moreram_osx_context.libc_free_func = 0;

    // Delete lock.
    [g_moreram_osx_context.lock release];
    g_moreram_osx_context.lock = 0;

    // Delete resources.
    moreram_osx_node_t* node = g_moreram_osx_context.head;
    while(node)
    {
       moreram_osx_node_t* next = node->next;
       [node->buffer release];
       node = next;
    }

    g_moreram_osx_context.head = 0;
    g_moreram_osx_context.tail = 0;

    // Delete device.
    [g_moreram_osx_context.device release];
    g_moreram_osx_context.device = 0;
}

void*
malloc(size_t size)
{
    void* mem = g_moreram_osx_context.libc_malloc_func(size);
    if(mem)
    {
        // We allocated memory conventionally.
        return mem;
    }

    size += sizeof(moreram_osx_node_t);

    [g_moreram_osx_context.lock lock];

    id<MTLBuffer> buffer = [g_moreram_osx_context.device newBufferWithLength: size options: MTLResourceCPUCacheModeDefaultCache];
    if(!buffer)
    {
        // Failed buffer allocation.
        errno = ENOMEM;
        [g_moreram_osx_context.lock unlock];
        return 0;
    }

    moreram_osx_node_t* node = (moreram_osx_node_t*) [node->buffer contents];
    node->address = node + 1;
    node->buffer = buffer;
    node->size = size - sizeof(moreram_osx_node_t);
    node->next = 0;
    node->prev = 0;

    if(g_moreram_osx_context.tail)
    {
        g_moreram_osx_context.tail->next = node;
        node->prev = g_moreram_osx_context.tail;
        g_moreram_osx_context.tail = node;
    }
    else
    {
        g_moreram_osx_context.head = node;
        g_moreram_osx_context.tail = node;
    }

    [g_moreram_osx_context.lock unlock];
    return node->address;
}

void
free(void* address)
{
    if(!address)
    {
        return;
    }

    [g_moreram_osx_context.lock lock];

    moreram_osx_node_t* node = g_moreram_osx_context.head;
    while(node)
    {
        if(node->address != address)
        {
            node = node->next;
            continue;
        }

        if(g_moreram_osx_context.head == node && g_moreram_osx_context.tail == node)
        {
            g_moreram_osx_context.head = 0;
            g_moreram_osx_context.tail = 0;
        }
        else if(g_moreram_osx_context.head == node)
        {
            g_moreram_osx_context.head = node->next;
            g_moreram_osx_context.tail = 0;
        }
        else if(g_moreram_osx_context.tail == node)
        {
            g_moreram_osx_context.tail = node->prev;
            g_moreram_osx_context.head = 0;
        }
        else
        {
            moreram_osx_node_t* next = node->next;
            moreram_osx_node_t* prev = node->prev;
            next->prev = prev;
            prev->next = next;
        }

        [node->buffer release];
        [g_moreram_osx_context.lock unlock];
        return;
    }

    [g_moreram_osx_context.lock unlock];

    // We did not find this address, forward to standard mem free.
    g_moreram_osx_context.libc_free_func(address);
}

void*
realloc(void* address, size_t size)
{
    if(!size)
    {
        free(address);
    }

    [g_moreram_osx_context.lock lock];

    moreram_osx_node_t* node = g_moreram_osx_context.head;
    while(node)
    {
        if(node->address != address)
        {
            node = node->next;
            continue;
        }

        // If we are shrinking, we can reuse same block.
        if(node->size >= size)
        {
            node->size = size;
            [g_moreram_osx_context.lock unlock];
            return address;
        }

        // Get more memory for resizing.
        [g_moreram_osx_context.lock unlock];
        void* resize = malloc(size);
        if(!resize)
        {
            return 0;
        }

        [g_moreram_osx_context.lock lock];

        memcpy(resize, address, node->size);

        if(g_moreram_osx_context.head == node && g_moreram_osx_context.tail == node)
        {
            g_moreram_osx_context.head = 0;
            g_moreram_osx_context.tail = 0;
        }
        else if(g_moreram_osx_context.head == node)
        {
            g_moreram_osx_context.head = node->next;
            g_moreram_osx_context.tail = 0;
        }
        else if(g_moreram_osx_context.tail == node)
        {
            g_moreram_osx_context.tail = node->prev;
            g_moreram_osx_context.head = 0;
        }
        else
        {
            moreram_osx_node_t* next = node->next;
            moreram_osx_node_t* prev = node->prev;
            next->prev = prev;
            prev->next = next;
        }

        [node->buffer release];
        [g_moreram_osx_context.lock unlock];

        return resize;
    }

    [g_moreram_osx_context.lock unlock];

    // We did not find this address, forward to standard mem realloc.
    return g_moreram_osx_context.libc_realloc_func(address, size);
}

void*
calloc(size_t num, size_t size)
{
    if(size && (num > (size_t) -1 / size))
    {
        errno = ENOMEM;
        return 0;
    }

    void* mem = g_moreram_osx_context.libc_calloc_func(num, size);
    if(mem)
    {
        // Allocated conventionally.
        return mem;
    }

    // Metal is guaranteed to zero the storage.
    mem = malloc(num * size);
    return mem;
}
