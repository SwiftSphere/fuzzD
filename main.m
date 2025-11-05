#include <stdint.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/stat.h>
#include <IOKit/IOKitLib.h>
#include <dirent.h>
#include <signal.h>

// ==================== MUTATOR CONFIGURATION ====================

typedef enum {
    MUTATE_BIT_FLIP,
    MUTATE_BYTE_SWAP,
    MUTATE_SPECIAL_VALUES,
    MUTATE_ARITHMETIC,
    MUTATE_BLOCK_DUPLICATE,
    MUTATE_ENDIAN_SWAP,
    MUTATE_RANDOM_NOISE,
    MUTATE_COUNT
} mutation_type_t;

typedef struct {
    int max_mutations_per_call;
    bool enable_nested_mutations;
} mutator_config_t;

mutator_config_t g_mutator_config = {
    .max_mutations_per_call = 3,
    .enable_nested_mutations = true
};

typedef struct {
    uint64_t value;
    const char *description;
} special_value_t;

special_value_t g_special_values[] = {
    {0, "NULL/zero"},
    {0xFFFFFFFFFFFFFFFF, "All ones"},
    {0x4141414141414141, "AAAAAAA"},
    {0xDEADBEEFDEADBEEF, "Deadbeef"},
    {0x8000000000000000, "Min int64"},
    {0x7FFFFFFFFFFFFFFF, "Max int64"},
    {0xFFFFFFFF00000000, "High ones"},
    {0x00000000FFFFFFFF, "Low ones"},
    {0xAAAAAAAAAAAAAAAA, "Alternating bits"},
    {0x5555555555555555, "Alternating bits2"}
};

static const size_t g_special_values_count = sizeof(g_special_values) / sizeof(g_special_values[0]);

// ==================== MUTATOR SYSTEM ====================

void mutate_bit_flip(void *data, size_t size, FILE *log) {
    if (!data || size == 0) return;
    
    int flips = 1 + (rand() % 5);
    for (int i = 0; i < flips; i++) {
        size_t offset = rand() % size;
        uint8_t *byte = (uint8_t *)data + offset;
        uint8_t bit_mask = 1 << (rand() % 8);
        *byte ^= bit_mask;
    }
}

void mutate_byte_swap(void *data, size_t size, FILE *log) {
    if (!data || size < 2) return;
    
    size_t idx1 = rand() % size;
    size_t idx2 = rand() % size;
    
    if (idx1 != idx2) {
        uint8_t *bytes = (uint8_t *)data;
        uint8_t temp = bytes[idx1];
        bytes[idx1] = bytes[idx2];
        bytes[idx2] = temp;
    }
}

void mutate_special_values(void *data, size_t size, FILE *log) {
    if (!data || size == 0) return;
    
    special_value_t special = g_special_values[rand() % g_special_values_count];
    
    if (size >= sizeof(uint64_t)) {
        size_t offset = rand() % (size - sizeof(uint64_t) + 1);
        memcpy((uint8_t *)data + offset, &special.value, sizeof(uint64_t));
    }
}

void mutate_arithmetic(void *data, size_t size, FILE *log) {
    if (!data || size == 0) return;
    
    size_t offset = rand() % size;
    uint8_t *byte = (uint8_t *)data + offset;
    
    int operation = rand() % 4;
    switch (operation) {
        case 0: *byte += 1 + (rand() % 10); break;
        case 1: *byte -= 1 + (rand() % 10); break;
        case 2: *byte *= 2; break;
        case 3: *byte /= 2; break;
    }
}

void mutate_endian_swap(void *data, size_t size, FILE *log) {
    if (!data || size < 2) return;
    
    int block_sizes[] = {2, 4, 8};
    int block_size = block_sizes[rand() % 3];
    
    if (size >= block_size) {
        size_t offset = rand() % (size - block_size + 1);
        uint8_t *block = (uint8_t *)data + offset;
        
        for (int i = 0; i < block_size / 2; i++) {
            uint8_t temp = block[i];
            block[i] = block[block_size - 1 - i];
            block[block_size - 1 - i] = temp;
        }
    }
}

void mutate_random_noise(void *data, size_t size, FILE *log) {
    if (!data || size == 0) return;
    
    int noise_percent = 10 + (rand() % 50);
    size_t noise_bytes = (size * noise_percent) / 100;
    
    for (size_t i = 0; i < noise_bytes; i++) {
        size_t offset = rand() % size;
        ((uint8_t *)data)[offset] = rand() % 256;
    }
}

void smart_mutator(void *data, size_t size, FILE *log) {
    if (!data || size == 0) return;
    
    int num_mutations = 1 + (rand() % g_mutator_config.max_mutations_per_call);
    
    for (int i = 0; i < num_mutations; i++) {
        mutation_type_t mutation_type = rand() % MUTATE_COUNT;
        
        switch (mutation_type) {
            case MUTATE_BIT_FLIP:
                mutate_bit_flip(data, size, log);
                break;
            case MUTATE_BYTE_SWAP:
                mutate_byte_swap(data, size, log);
                break;
            case MUTATE_SPECIAL_VALUES:
                mutate_special_values(data, size, log);
                break;
            case MUTATE_ARITHMETIC:
                mutate_arithmetic(data, size, log);
                break;
            case MUTATE_ENDIAN_SWAP:
                mutate_endian_swap(data, size, log);
                break;
            case MUTATE_RANDOM_NOISE:
                mutate_random_noise(data, size, log);
                break;
            default:
                break;
        }
    }
}

// ==================== MAIN FUZZER ====================

struct arg_struct {
    mach_port_t connection;
    uint32_t    selector;
    uint64_t   *input;
    uint32_t    inputCnt;
    void       *inputStruct;
    size_t      inputStructCnt;
    uint64_t   *output;
    uint32_t   *outputCnt;
    void       *outputStruct;
    size_t     *outputStructCntP;
};

char* get_documents_path(void) {
    static char path[1024];
    const char *home = getenv("HOME");
    if (home) {
        snprintf(path, sizeof(path), "%s/Documents/fuzzXD", home);
    } else {
        strcpy(path, "./Documents/fuzzXD");
    }
    return path;
}

int ensure_directory_exists(const char *path) {
    struct stat st;
    if (stat(path, &st) == -1) {
        return mkdir(path, 0700);
    }
    return 0;
}

int maybe(void) {
    static int seeded = 0;
    if(!seeded) {
        srand((unsigned int)time(NULL));
        seeded = 1;
    }
    return !(rand() % 100);
}

void racetemp(struct arg_struct *args) {
    if (!args) return;
    IOConnectCallMethod(args->connection, args->selector,
                       args->input, args->inputCnt,
                       args->inputStruct, args->inputStructCnt,
                       args->output, args->outputCnt,
                       args->outputStruct, args->outputStructCntP);
}

kern_return_t fake_IOConnectCallMethod(
  mach_port_t connection,
  uint32_t    selector,
  uint64_t   *input,
  uint32_t    inputCnt,
  void       *inputStruct,
  size_t      inputStructCnt,
  uint64_t   *output,
  uint32_t   *outputCnt,
  void       *outputStruct,
  size_t     *outputStructCntP,
  FILE        *f)
{
    kern_return_t kr;
    int watcher = 0;
    const int loop_limit = 1000;
    
    uint64_t *input_copy = NULL;
    void *inputStruct_copy = NULL;
    
    if (input && inputCnt > 0) {
        input_copy = malloc(inputCnt * sizeof(uint64_t));
        memcpy(input_copy, input, inputCnt * sizeof(uint64_t));
    }
    
    if (inputStruct && inputStructCnt > 0) {
        inputStruct_copy = malloc(inputStructCnt);
        memcpy(inputStruct_copy, inputStruct, inputStructCnt);
    }
    
    for (; watcher < loop_limit; watcher++) {
        if (input_copy && input) {
            memcpy(input_copy, input, inputCnt * sizeof(uint64_t));
        }
        if (inputStruct_copy && inputStruct) {
            memcpy(inputStruct_copy, inputStruct, inputStructCnt);
        }
        
        if (input_copy && inputCnt > 0) {
            smart_mutator(input_copy, inputCnt * sizeof(uint64_t), f);
        }
        
        if (inputStruct_copy && inputStructCnt > 0) {
            smart_mutator(inputStruct_copy, inputStructCnt, f);
        }
        
        kr = IOConnectCallMethod(connection, selector,
                                input_copy, inputCnt,
                                inputStruct_copy, inputStructCnt,
                                output, outputCnt,
                                outputStruct, outputStructCntP);
        
        if (kr != KERN_SUCCESS) {
            fprintf(f, "Call %d returned: 0x%x\n", watcher, kr);
        }
        
        struct arg_struct thread_args = {
            .connection = connection,
            .selector = selector,
            .input = input_copy,
            .inputCnt = inputCnt,
            .inputStruct = inputStruct_copy,
            .inputStructCnt = inputStructCnt,
            .output = output,
            .outputCnt = outputCnt,
            .outputStruct = outputStruct,
            .outputStructCntP = outputStructCntP
        };
        
        pthread_t t;
        if (pthread_create(&t, NULL, (void*(*)(void*))racetemp, &thread_args) == 0) {
            IOConnectCallMethod(connection, selector,
                              input_copy, inputCnt,
                              inputStruct_copy, inputStructCnt,
                              output, outputCnt,
                              outputStruct, outputStructCntP);
            pthread_join(t, NULL);
        }
        
        if (maybe()) {
            usleep(1000);
        }
    }
    
    free(input_copy);
    free(inputStruct_copy);
    
    return kr;
}

void fuzzXD(io_name_t class, uint32_t type, FILE *f) {
    kern_return_t kr;
    io_iterator_t iterator = IO_OBJECT_NULL;
    io_connect_t connect = MACH_PORT_NULL;
    
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching(class), &iterator);
    if (kr != KERN_SUCCESS) return;
    
    io_service_t service = IOIteratorNext(iterator);
    if (service == IO_OBJECT_NULL) {
        IOObjectRelease(iterator);
        return;
    }
    
    kr = IOServiceOpen(service, mach_task_self(), type, &connect);
    IOObjectRelease(iterator);
    IOObjectRelease(service);
    
    if (kr != KERN_SUCCESS) return;
    
    uint64_t interesting[] = {
        0, 1, -1, 0x41, 0x41414141, 0xFFFFFFFF,
        LONG_MAX, LONG_MIN, ULONG_MAX
    };
    size_t interesting_count = sizeof(interesting) / sizeof(interesting[0]);
    
    for (uint32_t sel = 0; sel < 30; sel++) {
        for (size_t inter = 0; inter < interesting_count; inter++) {
            uint64_t inputScalar[16] = {0};
            uint32_t inputScalarCnt = interesting[inter] % 16;
            
            for (uint32_t i = 0; i < inputScalarCnt; i++) {
                inputScalar[i] = interesting[inter];
            }
            
            char inputStruct[1024] = {0};
            size_t inputStructCnt = interesting[inter] % sizeof(inputStruct);
            
            uint64_t outputScalar[16] = {0};
            uint32_t outputScalarCnt = 16;
            
            char outputStruct[1024] = {0};
            size_t outputStructCnt = sizeof(outputStruct);
            
            kern_return_t err = fake_IOConnectCallMethod(
                connect, sel, inputScalar, inputScalarCnt,
                inputStruct, inputStructCnt, outputScalar, &outputScalarCnt,
                outputStruct, &outputStructCnt, f);
                
            if (err != KERN_SUCCESS) {
                fprintf(f, "Method %u error: 0x%x\n", sel, err);
            }
        }
    }
    
    IOServiceClose(connect);
}

int pickkexts(void) {
    kern_return_t kr;
    io_iterator_t iterator = IO_OBJECT_NULL;
    
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("IOService"), &iterator);
    if (kr != KERN_SUCCESS) return -1;
    
    const char *docs_path = get_documents_path();
    if (ensure_directory_exists(docs_path) != 0) {
        IOObjectRelease(iterator);
        return -1;
    }
    
    int processed = 0;
    io_service_t service;
    
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        io_name_t class_name = {0};
        IOObjectGetClass(service, class_name);
        
        if (strcmp(class_name, "IOPMrootDomain") == 0 ||
            strcmp(class_name, "IOPlatformExpert") == 0) {
            IOObjectRelease(service);
            continue;
        }
        
        char filepath[1024];
        snprintf(filepath, sizeof(filepath), "%s/%s.txt", docs_path, class_name);
        
        FILE *f = fopen(filepath, "w");
        if (!f) {
            IOObjectRelease(service);
            continue;
        }
        
        uint32_t types[] = {0, 1, 0xFFFFFFFF, 0x99000002, 0x484944};
        size_t type_count = sizeof(types) / sizeof(types[0]);
        
        for (size_t i = 0; i < type_count; i++) {
            io_connect_t connect = MACH_PORT_NULL;
            kr = IOServiceOpen(service, mach_task_self(), types[i], &connect);
            
            if (kr == KERN_SUCCESS) {
                fuzzXD(class_name, types[i], f);
                IOServiceClose(connect);
                break;
            }
        }
        
        fclose(f);
        IOObjectRelease(service);
        processed++;
        
        usleep(100000);
    }
    
    IOObjectRelease(iterator);
    return processed;
}

void initialize_mutator(void) {
    srand((unsigned int)time(NULL));
}

int main(int argc, const char * argv[]) {
    printf("IOKit fuzzer with smart mutator\n");
    printf("Log directory: %s\n", get_documents_path());
    
    initialize_mutator();
    int ret = pickkexts();
    
    printf("Fuzzing complete. Logs in: %s\n", get_documents_path());
    return ret;
}
