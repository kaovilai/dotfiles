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

	MaxModelLen   int
	OutputReserve int
	MinOutput     int
	BytesPerToken float64

	DefaultRetry   int
	ClientRetryMax int
	OutageBase     int
	OutageMax      int
	RequestTimeout time.Duration
	QuotaTZ        *time.Location
	UsageDir       string
	SearchDelegate string
	// SearchMCP names the web-search MCP server the launchers register for
	// sessions on this search-less upstream (T3_WEB_SEARCH_MCP, e.g. "parallel").
	SearchMCP string

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
		Flavor:         flavor,
		Port:           port,
		RuntimeDir:     runtimeDir,
		Token:          knob("PROXY_TOKEN", "hosted-only-local"),
		GLM:            knob("GLM_MODEL", "rits/zai-org/glm-5-3"),
		DeepSeek:       knob("DEEPSEEK_MODEL", "rits/deepseek-ai/DeepSeek-V4.1-Flash-1017"),
		Aliases:        aliases,
		BaseURL:        base,
		APIKey:         os.Getenv("ENMAAS_API_KEY"),
		VisionFallback: boolKnob("VISION_FALLBACK", true),
		FallbackOn:     boolKnob("FALLBACK", true),
		LimitRewrite:   boolKnob("LIMIT_REWRITE", true),
		OutageRewrite:  boolKnob("OUTAGE_REWRITE", true),
		SearchNudge:    boolKnob("SEARCH_NUDGE", true),
		MaxModelLen:    intKnob("MAX_MODEL_LEN", 1048576, 1024),
		OutputReserve:  intKnob("OUTPUT_RESERVE", 512, 0),
		MinOutput:      intKnob("MIN_OUTPUT", 16000, 1),
		BytesPerToken:  floatKnob("BYTES_PER_TOKEN", 3),
		DefaultRetry:   intKnob("RATE_LIMIT_DEFAULT_RETRY_SECONDS", 60, 1),
		ClientRetryMax: intKnob("CLIENT_RETRY_MAX_SECONDS", 60, 0),
		OutageBase:     intKnob("OUTAGE_RETRY_SECONDS", 60, 1),
		OutageMax:      intKnob("OUTAGE_RETRY_MAX_SECONDS", 600, 1),
		RequestTimeout: time.Duration(intKnob("REQUEST_TIMEOUT", 300, 1)) * time.Second,
		QuotaTZ:        tz,
		UsageDir:       usageDir,
		SearchDelegate: strings.TrimSpace(os.Getenv("T3_WEB_SEARCH_DELEGATE")),
		SearchMCP:      strings.TrimSpace(os.Getenv("T3_WEB_SEARCH_MCP")),
	}
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
