package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

func startDoHStub(t *testing.T, records map[string]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		body, ok := records[name]
		if !ok {
			body = `{"Status":3}`
		}
		w.Header().Set("content-type", "application/dns-json")
		_, _ = w.Write([]byte(body))
	}))
}

func TestDoHResolvesARecord(t *testing.T) {
	server := startDoHStub(t, map[string]string{
		"gateway.example": `{"Status":0,"Answer":[{"TTL":120,"type":1,"data":"192.0.2.10"}]}`,
	})
	t.Setenv("ENMAAS_DNS_FALLBACK_HOSTS", "gateway.example")
	t.Setenv("ENMAAS_DNS_DOH_URLS", server.URL+"/resolve?name=%s&type=A")
	doh := newDoHResolver()
	if !doh.allowed("Gateway.Example.") {
		t.Fatal("allow-list must normalize case and the trailing dot")
	}
	if doh.allowed("other.example") {
		t.Fatal("only allow-listed hosts")
	}
	addrs := doh.addresses(context.Background(), "gateway.example")
	if len(addrs) != 1 || addrs[0] != "192.0.2.10" {
		t.Fatalf("addresses: %v", addrs)
	}
}

func TestDoHFollowsCNAMEOnce(t *testing.T) {
	server := startDoHStub(t, map[string]string{
		"gateway.example": `{"Status":0,"Answer":[{"TTL":60,"type":5,"data":"real.example."}]}`,
		"real.example":    `{"Status":0,"Answer":[{"TTL":60,"type":1,"data":"192.0.2.20"}]}`,
	})
	t.Setenv("ENMAAS_DNS_FALLBACK_HOSTS", "gateway.example")
	t.Setenv("ENMAAS_DNS_DOH_URLS", server.URL+"/resolve?name=%s&type=A")
	doh := newDoHResolver()
	addrs := doh.addresses(context.Background(), "gateway.example")
	if len(addrs) != 1 || addrs[0] != "192.0.2.20" {
		t.Fatalf("CNAME follow: %v", addrs)
	}
}

func TestDoHSkipsFailedStatus(t *testing.T) {
	server := startDoHStub(t, nil) // every name answers NXDOMAIN
	t.Setenv("ENMAAS_DNS_FALLBACK_HOSTS", "gateway.example")
	t.Setenv("ENMAAS_DNS_DOH_URLS", server.URL+"/resolve?name=%s&type=A")
	doh := newDoHResolver()
	if addrs := doh.addresses(context.Background(), "gateway.example"); len(addrs) != 0 {
		t.Fatalf("a failed status must yield no addresses: %v", addrs)
	}
}

func TestDoHDisabledWithoutAllowList(t *testing.T) {
	doh := newDoHResolver()
	if doh.allowed("anything.example") {
		t.Fatal("an empty allow-list disables the fallback entirely")
	}
}

func TestDoHDialContextFallbackDialsResolvedAddress(t *testing.T) {
	// A local listener plays the resolved address. The system resolver cannot
	// resolve the reserved .example name, so the dial must go through the DoH
	// fallback and land on the listener's port.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	port := strconv.Itoa(listener.Addr().(*net.TCPAddr).Port)
	server := startDoHStub(t, map[string]string{
		"gateway.example": `{"Status":0,"Answer":[{"TTL":60,"type":1,"data":"127.0.0.1"}]}`,
	})
	t.Setenv("ENMAAS_DNS_FALLBACK_HOSTS", "gateway.example")
	t.Setenv("ENMAAS_DNS_DOH_URLS", server.URL+"/resolve?name=%s&type=A")
	doh := newDoHResolver()
	conn, err := dohDialContext(&net.Dialer{}, doh)(context.Background(), "tcp", "gateway.example:"+port)
	if err != nil {
		t.Fatalf("dial through the DoH fallback: %v", err)
	}
	_ = conn.Close()
}

func TestDoHDialContextRejectsHostsOutsideAllowList(t *testing.T) {
	// A name outside the allow-list gets the original DNS error back, with no
	// DoH attempt in between.
	server := startDoHStub(t, map[string]string{
		"gateway.example": `{"Status":0,"Answer":[{"TTL":60,"type":1,"data":"127.0.0.1"}]}`,
	})
	t.Setenv("ENMAAS_DNS_FALLBACK_HOSTS", "gateway.example")
	t.Setenv("ENMAAS_DNS_DOH_URLS", server.URL+"/resolve?name=%s&type=A")
	doh := newDoHResolver()
	dial := dohDialContext(&net.Dialer{}, doh)
	_, err := dial(context.Background(), "tcp", "other.example:80")
	if err == nil {
		t.Fatal("an unresolvable non-allow-listed host must fail")
	}
	var dnsErr *net.DNSError
	if !errors.As(err, &dnsErr) {
		t.Fatalf("want the original DNS error, got %v", err)
	}
}
