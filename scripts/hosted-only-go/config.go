package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// config mirrors the HOSTED_ONLY_* knobs read by hosted_only_hooks.py and
// hosted-only-proxy.zsh, so the Go path behaves like the LiteLLM path.
type config struct {
	Flavor     string // claude | codex
	Port       string
	RuntimeDir string
	Token      string

	GLM      string
	DeepSeek string
	Aliases  map[string]struct{}

	BaseURL string // gateway root, no trailing slash and no /v1 suffix
	APIKey  string

	VisionFallback bool
	FallbackOn     bool
	LimitRewrite   bool
	OutageRewrite  bool
	SearchNudge    bool
	// ClassifierRouteModel pins detected auto-mode classifier calls to this
	// model id ("" = off). See server.go.
	ClassifierRouteModel string

	MaxModelLen   int
	OutputReserve int
	MinOutput     int
	BytesPerToken float64

	// Inline image handling (hosted_only_hooks.py item 6): the gateway caps a
	// request body and answers 413, so old inline images are replaced
	// oldest-first once the content exceeds ImageBudget. ImageTokens prices
	// each image in the clamp (base64 bytes are not tokens).
	ImageBudget    int
	ImageTokens    int
	ImageCacheDays int
	ImageCacheDir  string
	AttachmentsDir string

	DefaultRetry   int
	ClientRetryMax int
	OutageBase     int
	OutageMax      int
	OutageState    string // HOSTED_ONLY_OUTAGE_STATE: streaks survive a restart
	OutageCoalesce float64
	RequestTimeout time.Duration
	QuotaTZ        *time.Location
	UsageDir       string
	SearchDelegate string
	// SearchMCP names the web-search MCP server the launchers register for
	// sessions on this search-less upstream (T3_WEB_SEARCH_MCP, e.g. "parallel").
	SearchMCP string

	// Web-search shim (docs/notes/web-search-shim.md): HOSTED_ONLY_SEARCH_SHIM
	// emulates the hosted web_search server tool proxy-side against the
	// Parallel Search API for verdict-*ignored* models. Off by default until
	// soaked; participating in the knob/fingerprint restart machinery.
	SearchShim       bool
	SearchVerdicts   string // verdict cache file (model+gateway -> verdict, TTL'd)
	SearchDailyCap   int    // proxy-side daily ceiling on executed searches
	ParallelBase     string
	ParallelKey      string // env PARALLEL_API_KEY (auth ladder tier 1)
	ParallelState    string // OAuth-minted key + budget counter state dir
	ParallelPlatform string // OAuth device-flow base (platform.parallel.ai)
	ParallelMCP      string // anonymous free tier: the keyless MCP endpoint
	ParallelAccount  string // Account API base (key minting)

	// Routes is set for the enmaas flavor: the launcher's generated LiteLLM
	// config.json, read as a model -> deployment table.
	Routes *routeTable
}

// knob reads HOSTED_ONLY_<name>, then the retired GLM_HYBRID_<name>, then def.
func knob(name, def string) string {
	if v := os.Getenv("HOSTED_ONLY_" + name); v != "" {
		return v
	}
	if v := os.Getenv("GLM_HYBRID_" + name); v != "" {
		return v
	}
	return def
}

func intKnob(name string, def, min int) int {
	v, err := strconv.Atoi(strings.TrimSpace(knob(name, strconv.Itoa(def))))
	if err != nil {
		return def
	}
	if v < min {
		return min
	}
	return v
}

func boolKnob(name string, def bool) bool {
	d := "1"
	if !def {
		d = "0"
	}
	return knob(name, d) != "0"
}

func floatKnob(name string, def float64) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(knob(name, strconv.FormatFloat(def, 'f', -1, 64))), 64)
	if err != nil || v < 1 {
		return def
	}
	return v
}

// imageCacheDir is HOSTED_ONLY_IMAGE_CACHE_DIR, else
// $XDG_STATE_HOME/hosted-only-image-cache (~/.local/state when unset). An
// override must be a directory dedicated to this proxy: the sweep deletes
// expired <sha1>.<ext> files in it.
func imageCacheDir() string {
	if dir := knob("IMAGE_CACHE_DIR", ""); dir != "" {
		return dir
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = os.Getenv("HOME") + "/.local/state"
	}
	return state + "/hosted-only-image-cache"
}

// coalesceKnob reads HOSTED_ONLY_OUTAGE_COALESCE_SECONDS like the Python hook:
// any parseable float is accepted (0.5 and 0 are valid same-episode windows),
// unlike floatKnob which floors at 1 for the bytes-per-token ratio.
func coalesceKnob() float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(knob("OUTAGE_COALESCE_SECONDS", "5")), 64)
	if err != nil {
		return 5
	}
	return v
}

func dialectSuffixFor(flavor string) string {
	if flavor == "enmaas" {
		return knob("DIALECT_SUFFIX", "")
	}
	return knob("DIALECT_SUFFIX", "#openai")
}

func loadConfig(flavor, port, runtimeDir string) *config {
	base := knob("ENMAAS_BASE_URL", strings.TrimSpace(os.Getenv("ENMAAS_API_BASE_URL")))
	if base == "" {
		base = "https://api.enmaas.devshift.net"
	}
	base = strings.TrimRight(base, "/")
	base = strings.TrimSuffix(base, "/v1")

	aliases := map[string]struct{}{}
	for _, a := range strings.Split(knob("ALIAS_MODELS", ""), ",") {
		if a = strings.TrimSpace(a); a != "" {
			aliases[a] = struct{}{}
		}
	}

	tzName := strings.TrimSpace(os.Getenv("HOSTED_ONLY_QUOTA_MONTH_TZ"))
	if tzName == "" {
		tzName = "UTC"
	}
	tz, err := time.LoadLocation(tzName)
	if err != nil {
		tz = time.UTC
	}

	usageDir := os.Getenv("LLM_USAGE_DIR")
	if usageDir == "" {
		state := os.Getenv("XDG_STATE_HOME")
		if state == "" {
			state = os.Getenv("HOME") + "/.local/state"
		}
		usageDir = state + "/llm-usage"
	}

	return &config{
		Flavor:               flavor,
		Port:                 port,
		RuntimeDir:           runtimeDir,
		Token:                knob("PROXY_TOKEN", "hosted-only-local"),
		GLM:                  knob("GLM_MODEL", "rits/zai-org/glm-5-3"),
		DeepSeek:             knob("DEEPSEEK_MODEL", "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017"),
		Aliases:              aliases,
		BaseURL:              base,
		APIKey:               os.Getenv("ENMAAS_API_KEY"),
		VisionFallback:       boolKnob("VISION_FALLBACK", true),
		FallbackOn:           boolKnob("FALLBACK", true),
		LimitRewrite:         boolKnob("LIMIT_REWRITE", true),
		OutageRewrite:        boolKnob("OUTAGE_REWRITE", true),
		SearchNudge:          boolKnob("SEARCH_NUDGE", true),
		ClassifierRouteModel: knob("CLASSIFIER_ROUTE_MODEL", ""),
		MaxModelLen:          intKnob("MAX_MODEL_LEN", 1048576, 1024),
		OutputReserve:        intKnob("OUTPUT_RESERVE", 512, 0),
		MinOutput:            intKnob("MIN_OUTPUT", 16000, 1),
		BytesPerToken:        floatKnob("BYTES_PER_TOKEN", 3),
		ImageBudget:          intKnob("IMAGE_BUDGET_BYTES", 2500000, 0),
		ImageTokens:          intKnob("IMAGE_TOKENS", 2500, 1),
		ImageCacheDays:       intKnob("IMAGE_CACHE_DAYS", 1, 0),
		ImageCacheDir:        imageCacheDir(),
		AttachmentsDir:       os.Getenv("HOME") + "/.t3/userdata/attachments",
		DefaultRetry:         intKnob("RATE_LIMIT_DEFAULT_RETRY_SECONDS", 60, 1),
		ClientRetryMax:       intKnob("CLIENT_RETRY_MAX_SECONDS", 60, 0),
		OutageBase:           intKnob("OUTAGE_RETRY_SECONDS", 60, 1),
		OutageMax:            intKnob("OUTAGE_RETRY_MAX_SECONDS", 600, 1),
		OutageState:          strings.TrimSpace(knob("OUTAGE_STATE", "")),
		OutageCoalesce:       coalesceKnob(),
		RequestTimeout:       time.Duration(intKnob("REQUEST_TIMEOUT", 300, 1)) * time.Second,
		QuotaTZ:              tz,
		UsageDir:             usageDir,
		SearchDelegate:       strings.TrimSpace(os.Getenv("T3_WEB_SEARCH_DELEGATE")),
		SearchMCP:            strings.TrimSpace(os.Getenv("T3_WEB_SEARCH_MCP")),
		SearchShim:           boolKnob("SEARCH_SHIM", false),
		SearchVerdicts:       strings.TrimSpace(knob("SEARCH_VERDICTS", "")),
		SearchDailyCap:       intKnob("SEARCH_DAILY_CAP", 500, 0),
		ParallelBase:         strings.TrimRight(knob("PARALLEL_BASE", "https://api.parallel.ai"), "/"),
		ParallelKey:          strings.TrimSpace(os.Getenv("PARALLEL_API_KEY")),
		ParallelState:        strings.TrimSpace(knob("PARALLEL_STATE", runtimeDir)),
		ParallelPlatform:     strings.TrimRight(knob("PARALLEL_PLATFORM", "https://platform.parallel.ai"), "/"),
		ParallelMCP:          strings.TrimRight(knob("PARALLEL_MCP", "https://mcp.parallel.ai/mcp"), "/"),
		ParallelAccount:      strings.TrimRight(knob("PARALLEL_ACCOUNT", "https://api.parallel.ai/account"), "/"),
	}
}

// stateDir is where the shim keeps its verdict cache, OAuth-minted Parallel
// key, and daily budget counter: the proxy runtime dir when the launcher gave
// one, else XDG state.
func (c *config) shimStateDir() string {
	if c.ParallelState != "" {
		return c.ParallelState
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = os.Getenv("HOME") + "/.local/state"
	}
	return state + "/hosted-only-shim"
}

// isGLM reports whether the served model id is GLM or an alias served by GLM.
func (c *config) isGLM(model string) bool {
	if model == c.GLM {
		return true
	}
	_, ok := c.Aliases[model]
	return ok
}

// isRits reports whether the hooks' rits/ workarounds apply to this model.
func (c *config) isRits(model string) bool {
	return strings.HasPrefix(model, "rits/") || c.isGLM(model)
}

// allowedModel is the hosted-only cost guard: only the two hosted models and
// their aliases may be served. The enmaas flavor is governed by its route table
// instead.
func (c *config) allowedModel(model string) bool {
	if model == c.GLM || model == c.DeepSeek {
		return true
	}
	_, alias := c.Aliases[model]
	return alias
}
