package main

// DoH fallback for the gateway name, ported from scripts/dns_fallback.py: a
// stale manual DNS server on one network service can break the gateway name
// while everything else still works, so the failed name is retried over
// DNS-over-HTTPS and every other name is left to the system resolver (which
// answers first and always wins — split-horizon and VPN names keep their real
// records).
//
// Knobs (the launcher pins them; all optional):
//
//	ENMAAS_DNS_FALLBACK_HOSTS  comma-separated allow-list; empty disables it
//	ENMAAS_DNS_DOH_URLS        comma-separated URL templates with one %s

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

var defaultDoH = []string{
	"https://1.1.1.1/dns-query?name=%s&type=A",
	"https://1.0.0.1/dns-query?name=%s&type=A",
	"https://8.8.8.8/resolve?name=%s&type=A",
	"https://dns.google/resolve?name=%s&type=A",
}

const (
	dohTimeout  = 3 * time.Second
	dohMinTTL   = 30 * time.Second
	dohMaxTTL   = 5 * time.Minute
	dohMaxDepth = 2
)

type dohEntry struct {
	expires time.Time
	addrs   []string
}

type dohResolver struct {
	hosts map[string]struct{}
	urls  []string

	mu    sync.Mutex
	cache map[string]dohEntry
}

func normalizeDoHHost(host string) string {
	host = strings.TrimSpace(host)
	host = strings.TrimSuffix(host, ".")
	return strings.ToLower(host)
}

func newDoHResolver() *dohResolver {
	hosts := map[string]struct{}{}
	for _, host := range strings.Split(os.Getenv("ENMAAS_DNS_FALLBACK_HOSTS"), ",") {
		if host = normalizeDoHHost(host); host != "" {
			hosts[host] = struct{}{}
		}
	}
	urls := defaultDoH
	if raw := strings.TrimSpace(os.Getenv("ENMAAS_DNS_DOH_URLS")); raw != "" {
		var list []string
		for _, url := range strings.Split(raw, ",") {
			if url = strings.TrimSpace(url); url != "" {
				list = append(list, url)
			}
		}
		if len(list) > 0 {
			urls = list
		}
	}
	return &dohResolver{hosts: hosts, urls: urls, cache: map[string]dohEntry{}}
}

// allowed reports whether the fallback applies to this name. An empty
// allow-list disables the whole mechanism, like dns_fallback.py.
func (d *dohResolver) allowed(host string) bool {
	if len(d.hosts) == 0 {
		return false
	}
	_, ok := d.hosts[normalizeDoHHost(host)]
	return ok
}

// addresses serves from cache when fresh, else resolves over DoH. The ctx
// bounds the DoH requests, so a cancelled dial stops the lookup.
func (d *dohResolver) addresses(ctx context.Context, host string) []string {
	key := normalizeDoHHost(host)
	d.mu.Lock()
	if entry, ok := d.cache[key]; ok && time.Now().Before(entry.expires) {
		d.mu.Unlock()
		return entry.addrs
	}
	d.mu.Unlock()
	addrs, ttl := d.lookup(ctx, key, 0)
	if len(addrs) > 0 {
		d.mu.Lock()
		d.cache[key] = dohEntry{expires: time.Now().Add(ttl), addrs: addrs}
		d.mu.Unlock()
	}
	return addrs
}

// lookup asks each DoH server in turn; (addresses, ttl), or ([], 0) when none
// answer. Only a CNAME coming back is followed once rather than giving up.
func (d *dohResolver) lookup(ctx context.Context, host string, depth int) ([]string, time.Duration) {
	client := &http.Client{Timeout: dohTimeout}
	for _, template := range d.urls {
		url := template
		if strings.Contains(template, "%s") {
			url = strings.Replace(template, "%s", host, 1)
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			continue
		}
		req.Header.Set("accept", "application/dns-json")
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_ = resp.Body.Close()
		var document struct {
			Status *int `json:"Status"`
			Answer []struct {
				TTL  int    `json:"TTL"`
				Type int    `json:"type"`
				Data string `json:"data"`
			} `json:"Answer"`
		}
		if json.Unmarshal(body, &document) != nil {
			continue
		}
		if document.Status != nil && *document.Status != 0 {
			continue
		}
		addrs := []string{}
		ttl := 0
		alias := ""
		for _, answer := range document.Answer {
			if answer.TTL > ttl {
				ttl = answer.TTL
			}
			switch answer.Type {
			case 1, 28:
				addrs = append(addrs, answer.Data)
			case 5:
				if alias == "" {
					alias = normalizeDoHHost(answer.Data)
				}
			}
		}
		if len(addrs) > 0 {
			clamped := time.Duration(ttl) * time.Second
			if clamped < dohMinTTL {
				clamped = dohMinTTL
			}
			if clamped > dohMaxTTL {
				clamped = dohMaxTTL
			}
			return addrs, clamped
		}
		if alias != "" && depth < dohMaxDepth && !d.allowed(alias) {
			return d.lookup(ctx, alias, depth+1)
		}
	}
	return nil, 0
}

// dohDialContext wraps the system-resolver dialer: only a DNS failure for an
// allow-listed host falls back to DoH addresses, dialed directly (TLS SNI and
// the Host header keep the original name).
func dohDialContext(base *net.Dialer, doh *dohResolver) func(ctx context.Context, network, addr string) (net.Conn, error) {
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		conn, err := base.DialContext(ctx, network, addr)
		if err == nil {
			return conn, nil
		}
		var dnsErr *net.DNSError
		if !errors.As(err, &dnsErr) {
			return nil, err
		}
		host, port, splitErr := net.SplitHostPort(addr)
		if splitErr != nil || !doh.allowed(host) {
			return nil, err
		}
		for _, ip := range doh.addresses(ctx, host) {
			if conn, dialErr := base.DialContext(ctx, network, net.JoinHostPort(ip, port)); dialErr == nil {
				return conn, nil
			}
		}
		return nil, err
	}
}
