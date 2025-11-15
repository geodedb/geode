// Minimal MsQuic server to test PEER_STREAM_STARTED event
#include <msquic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

const QUIC_API_TABLE* MsQuic = NULL;
HQUIC Registration = NULL;
HQUIC Configuration = NULL;
HQUIC Listener = NULL;

volatile int StreamReceived = 0;

QUIC_STATUS QUIC_API StreamCallback(HQUIC Stream, void* Context, QUIC_STREAM_EVENT* Event) {
    printf("[STREAM_CALLBACK] Event type: %d\n", Event->Type);
    switch (Event->Type) {
        case QUIC_STREAM_EVENT_START_COMPLETE:
            printf("[STREAM] START_COMPLETE\n");
            break;
        case QUIC_STREAM_EVENT_RECEIVE:
            printf("[STREAM] RECEIVE - BufferCount=%u\n", Event->RECEIVE.BufferCount);
            break;
        case QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN:
            printf("[STREAM] PEER_SEND_SHUTDOWN\n");
            break;
        case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
            printf("[STREAM] SHUTDOWN_COMPLETE\n");
            MsQuic->StreamClose(Stream);
            break;
        default:
            break;
    }
    return QUIC_STATUS_SUCCESS;
}

QUIC_STATUS QUIC_API ConnectionCallback(HQUIC Connection, void* Context, QUIC_CONNECTION_EVENT* Event) {
    printf("[CONNECTION_CALLBACK] Event type: %d\n", Event->Type);
    switch (Event->Type) {
        case QUIC_CONNECTION_EVENT_CONNECTED:
            printf("[CONNECTION] ✅ CONNECTED\n");
            break;
        case QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED:
            printf("[CONNECTION] ✅ PEER_STREAM_STARTED - Stream handle: %p\n", Event->PEER_STREAM_STARTED.Stream);
            StreamReceived = 1;
            MsQuic->SetCallbackHandler(Event->PEER_STREAM_STARTED.Stream, (void*)StreamCallback, NULL);
            break;
        case QUIC_CONNECTION_EVENT_PEER_NEEDS_STREAMS:
            printf("[CONNECTION] ❌ PEER_NEEDS_STREAMS - Bidirectional=%d\n", 
                   Event->PEER_NEEDS_STREAMS.Bidirectional);
            break;
        case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
            printf("[CONNECTION] SHUTDOWN_COMPLETE\n");
            MsQuic->ConnectionClose(Connection);
            break;
        default:
            break;
    }
    return QUIC_STATUS_SUCCESS;
}

QUIC_STATUS QUIC_API ListenerCallback(HQUIC Listener, void* Context, QUIC_LISTENER_EVENT* Event) {
    printf("[LISTENER_CALLBACK] Event type: %d\n", Event->Type);
    switch (Event->Type) {
        case QUIC_LISTENER_EVENT_NEW_CONNECTION:
            printf("[LISTENER] ✅ NEW_CONNECTION - Connection handle: %p\n", Event->NEW_CONNECTION.Connection);
            MsQuic->SetCallbackHandler(Event->NEW_CONNECTION.Connection, (void*)ConnectionCallback, NULL);
            
            QUIC_STATUS status = MsQuic->ConnectionSetConfiguration(Event->NEW_CONNECTION.Connection, Configuration);
            printf("[LISTENER] ConnectionSetConfiguration status: 0x%x\n", status);
            return QUIC_STATUS_SUCCESS;
        case QUIC_LISTENER_EVENT_STOP_COMPLETE:
            printf("[LISTENER] STOP_COMPLETE\n");
            break;
        default:
            break;
    }
    return QUIC_STATUS_SUCCESS;
}

int main(int argc, char* argv[]) {
    printf("=== MsQuic Minimal Server Test ===\n");
    
    // Load MsQuic
    QUIC_STATUS status = MsQuicOpen2(&MsQuic);
    if (QUIC_FAILED(status)) {
        printf("❌ MsQuicOpen2 failed: 0x%x\n", status);
        return 1;
    }
    printf("✅ MsQuic loaded\n");
    
    // Create registration
    const QUIC_REGISTRATION_CONFIG RegConfig = { "test_minimal", QUIC_EXECUTION_PROFILE_LOW_LATENCY };
    status = MsQuic->RegistrationOpen(&RegConfig, &Registration);
    if (QUIC_FAILED(status)) {
        printf("❌ RegistrationOpen failed: 0x%x\n", status);
        return 1;
    }
    printf("✅ Registration created\n");
    
    // Configure settings with PeerBidiStreamCount
    QUIC_SETTINGS Settings = {0};
    Settings.IdleTimeoutMs = 30000;
    Settings.IsSet.IdleTimeoutMs = TRUE;
    Settings.PeerBidiStreamCount = 100;
    Settings.IsSet.PeerBidiStreamCount = TRUE;
    Settings.PeerUnidiStreamCount = 100;
    Settings.IsSet.PeerUnidiStreamCount = TRUE;
    
    printf("Settings: PeerBidiStreamCount=%d, PeerUnidiStreamCount=%d\n", 
           Settings.PeerBidiStreamCount, Settings.PeerUnidiStreamCount);
    
    // Create configuration
    QUIC_BUFFER AlpnBuffer = { sizeof("geode/1") - 1, (uint8_t*)"geode/1" };
    status = MsQuic->ConfigurationOpen(Registration, &AlpnBuffer, 1, &Settings, sizeof(Settings), NULL, &Configuration);
    if (QUIC_FAILED(status)) {
        printf("❌ ConfigurationOpen failed: 0x%x\n", status);
        return 1;
    }
    printf("✅ Configuration created\n");
    
    // Load self-signed certificate
    QUIC_CERTIFICATE_FILE CertFile = {
        "./data_test_msquic/server.key",
        "./data_test_msquic/server.crt"
    };
    
    QUIC_CREDENTIAL_CONFIG CredConfig = {0};
    CredConfig.Type = QUIC_CREDENTIAL_TYPE_CERTIFICATE_FILE;
    CredConfig.CertificateFile = &CertFile;
    CredConfig.Flags = QUIC_CREDENTIAL_FLAG_NONE;
    
    status = MsQuic->ConfigurationLoadCredential(Configuration, &CredConfig);
    if (QUIC_FAILED(status)) {
        printf("❌ ConfigurationLoadCredential failed: 0x%x\n", status);
        return 1;
    }
    printf("✅ Certificate loaded\n");
    
    // Create listener
    status = MsQuic->ListenerOpen(Registration, ListenerCallback, NULL, &Listener);
    if (QUIC_FAILED(status)) {
        printf("❌ ListenerOpen failed: 0x%x\n", status);
        return 1;
    }
    printf("✅ Listener created\n");
    
    // Start listening
    QUIC_ADDR Address = {0};
    QuicAddrSetFamily(&Address, QUIC_ADDRESS_FAMILY_INET);
    QuicAddrSetPort(&Address, 17567);
    
    status = MsQuic->ListenerStart(Listener, &AlpnBuffer, 1, &Address);
    if (QUIC_FAILED(status)) {
        printf("❌ ListenerStart failed: 0x%x\n", status);
        return 1;
    }
    printf("✅ Listening on port 17567\n");
    
    // Wait for stream
    printf("\n⏳ Waiting for client to connect and open stream...\n");
    printf("   Run: python test_msquic_protocol.py --port 17567\n\n");
    
    for (int i = 0; i < 60; i++) {
        if (StreamReceived) {
            printf("\n🎉 Stream received successfully!\n");
            break;
        }
        sleep(1);
    }
    
    if (!StreamReceived) {
        printf("\n❌ No stream received after 60 seconds\n");
    }
    
    // Cleanup
    printf("\nCleaning up...\n");
    if (Listener) MsQuic->ListenerClose(Listener);
    if (Configuration) MsQuic->ConfigurationClose(Configuration);
    if (Registration) MsQuic->RegistrationClose(Registration);
    MsQuicClose(MsQuic);
    
    printf("✅ Cleanup complete\n");
    return StreamReceived ? 0 : 1;
}
