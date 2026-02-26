package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

func main() {
	listenAddr := getenv("A_LISTEN_ADDR", ":18080")
	initTimeout := getenvDuration("A_INIT_TIMEOUT", 30*time.Minute)
	kubeconfigTimeout := getenvDuration("A_KUBECONFIG_TIMEOUT", 30*time.Second)
	enableKubectlProxy := getenvBool("A_ENABLE_KUBECTL_PROXY", true)
	proxyManager := newKubectlProxyManager(enableKubectlProxy)

	proxyManager.Start(context.Background())

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintln(w, "ok")
	})

	mux.HandleFunc("/init", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed, use POST", http.StatusMethodNotAllowed)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), initTimeout)
		defer cancel()

		start := time.Now()
		output, err := runInitStep(ctx)
		cost := time.Since(start)

		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = fmt.Fprintf(w, "init failed: %v\ncost: %s\n\n--- install log ---\n%s", err, cost, output)
			return
		}

		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, "init success\ncost: %s\n\n--- install log ---\n%s", cost, output)
	})

	mux.HandleFunc("/kubeconfig", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed, use POST", http.StatusMethodNotAllowed)
			return
		}

		onesURLInput := r.URL.Query().Get("ones_url")
		if strings.TrimSpace(onesURLInput) == "" {
			onesURLInput = os.Getenv("ONES_INSTANCE_URL")
		}
		if strings.TrimSpace(onesURLInput) == "" {
			autoURL, candidates, err := detectOnesURLFromWikiAPI(r.Context())
			if err != nil {
				http.Error(w, fmt.Sprintf("auto detect ones_url failed: %v", err), http.StatusInternalServerError)
				return
			}
			log.Printf("auto detected ones_url from wiki-api hosts, candidates=%v, selected=%s", candidates, autoURL)
			onesURLInput = autoURL
		}

		serverAddr, err := buildClusterServer(onesURLInput)
		if err != nil {
			http.Error(w, fmt.Sprintf("invalid ones url: %v", err), http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), kubeconfigTimeout)
		defer cancel()

		rawConfig, err := runKubectlConfigViewRaw(ctx)
		if err != nil {
			http.Error(w, fmt.Sprintf("kubectl config view --raw failed: %v", err), http.StatusInternalServerError)
			return
		}

		modified, err := rewriteKubeconfig(rawConfig, serverAddr)
		if err != nil {
			http.Error(w, fmt.Sprintf("rewrite kubeconfig failed: %v", err), http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/x-yaml; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(modified)
	})

	mux.HandleFunc("/proxy/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodPost {
			http.Error(w, "method not allowed, use GET or POST", http.StatusMethodNotAllowed)
			return
		}

		restarted := false
		forceRestart := parseBoolQuery(r.URL.Query().Get("force_restart"))
		if forceRestart {
			if err := proxyManager.RequestRestart(); err != nil {
				http.Error(w, fmt.Sprintf("force restart failed: %v", err), http.StatusBadRequest)
				return
			}
			restarted = true
		}

		resp := map[string]interface{}{
			"requested_force_restart": restarted,
			"proxy":                   proxyManager.Status(),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	})

	server := &http.Server{
		Addr:              listenAddr,
		Handler:           logMiddleware(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("migi listening on %s", listenAddr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("listen failed: %v", err)
	}
}

func runInitStep(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(
		ctx,
		"/root/sync_image_decoded.sh",
		"img.ones.pro/dev/telepresenceio/tel2:2.22.4",
		"localhost:5000/ones/telepresenceio/tel2:2.22.4",
	)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func runKubectlConfigViewRaw(ctx context.Context) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "kubectl", "config", "view", "--raw")
	return cmd.CombinedOutput()
}

func runKubectl(ctx context.Context, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "kubectl", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("kubectl %s failed: %w, output=%s", strings.Join(args, " "), err, string(out))
	}
	return out, nil
}

type kubectlProxyManager struct {
	mu sync.Mutex

	enabled              bool
	cmd                  *exec.Cmd
	running              bool
	startTime            time.Time
	exitTime             time.Time
	lastError            string
	consecutiveFailures  int
	maxConsecutiveFailed int
	autoRestartPaused    bool

	restartCh chan struct{}
}

type kubectlProxyStatus struct {
	Enabled             bool   `json:"enabled"`
	Running             bool   `json:"running"`
	PID                 int    `json:"pid,omitempty"`
	StartTime           string `json:"start_time,omitempty"`
	ExitTime            string `json:"last_exit_time,omitempty"`
	LastError           string `json:"last_error,omitempty"`
	ConsecutiveFailures int    `json:"consecutive_failures"`
	MaxFailures         int    `json:"max_failures"`
	AutoRestartPaused   bool   `json:"auto_restart_paused"`
}

func newKubectlProxyManager(enabled bool) *kubectlProxyManager {
	return &kubectlProxyManager{
		enabled:              enabled,
		maxConsecutiveFailed: 10,
		restartCh:            make(chan struct{}, 1),
	}
}

func (m *kubectlProxyManager) Start(ctx context.Context) {
	if !m.enabled {
		return
	}

	go func() {
		for {
			if ctx.Err() != nil {
				return
			}

			m.mu.Lock()
			paused := m.autoRestartPaused
			m.mu.Unlock()
			if paused {
				select {
				case <-ctx.Done():
					return
				case <-m.restartCh:
					m.mu.Lock()
					m.autoRestartPaused = false
					m.lastError = ""
					m.consecutiveFailures = 0
					m.mu.Unlock()
					log.Printf("kubectl proxy manual restart requested, resume from paused state")
					continue
				}
			}

			log.Printf("starting kubectl proxy on 0.0.0.0:8080")
			cmd := exec.CommandContext(
				ctx,
				"kubectl",
				"proxy",
				"--port=8080",
				"--address=0.0.0.0",
				"--accept-hosts=^.*$",
				"--disable-filter=true",
			)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr

			if err := cmd.Start(); err != nil {
				m.mu.Lock()
				m.running = false
				m.lastError = err.Error()
				m.exitTime = time.Now()
				m.consecutiveFailures++
				if m.consecutiveFailures >= m.maxConsecutiveFailed {
					m.autoRestartPaused = true
					m.lastError = fmt.Sprintf("reached max restart failures (%d): %v", m.maxConsecutiveFailed, err)
				}
				pausedNow := m.autoRestartPaused
				m.mu.Unlock()
				if pausedNow {
					log.Printf("kubectl proxy start failed and paused auto-restart: %v", err)
					continue
				}
				log.Printf("kubectl proxy start failed: %v, retry in 3s", err)
				time.Sleep(3 * time.Second)
				continue
			}

			m.mu.Lock()
			m.cmd = cmd
			m.running = true
			m.startTime = time.Now()
			m.mu.Unlock()

			waitCh := make(chan error, 1)
			go func() {
				waitCh <- cmd.Wait()
			}()

			var waitErr error
			select {
			case <-ctx.Done():
				_ = cmd.Process.Kill()
				waitErr = <-waitCh
			case <-m.restartCh:
				log.Printf("kubectl proxy force restart requested")
				_ = cmd.Process.Kill()
				waitErr = <-waitCh
			case waitErr = <-waitCh:
			}

			m.mu.Lock()
			m.running = false
			m.cmd = nil
			m.exitTime = time.Now()
			if waitErr == nil {
				m.consecutiveFailures = 0
				m.lastError = ""
			} else if ctx.Err() == nil {
				m.lastError = waitErr.Error()
				m.consecutiveFailures++
				if m.consecutiveFailures >= m.maxConsecutiveFailed {
					m.autoRestartPaused = true
					m.lastError = fmt.Sprintf("reached max restart failures (%d): %v", m.maxConsecutiveFailed, waitErr)
				}
			}
			pausedNow := m.autoRestartPaused
			m.mu.Unlock()

			if ctx.Err() != nil {
				return
			}

			if waitErr == nil {
				log.Printf("kubectl proxy exited normally, restarting in 2s")
				time.Sleep(2 * time.Second)
				continue
			}

			if pausedNow {
				log.Printf("kubectl proxy reached max restart failures, auto-restart paused; wait for manual force restart")
				continue
			}

			log.Printf("kubectl proxy exited: %v, restarting in 3s", waitErr)
			time.Sleep(3 * time.Second)
		}
	}()
}

func (m *kubectlProxyManager) RequestRestart() error {
	if !m.enabled {
		return errors.New("kubectl proxy is disabled")
	}
	select {
	case m.restartCh <- struct{}{}:
		return nil
	default:
		// restart request already pending
		return nil
	}
}

func (m *kubectlProxyManager) Status() kubectlProxyStatus {
	m.mu.Lock()
	defer m.mu.Unlock()

	status := kubectlProxyStatus{
		Enabled:             m.enabled,
		Running:             m.running,
		LastError:           m.lastError,
		ConsecutiveFailures: m.consecutiveFailures,
		MaxFailures:         m.maxConsecutiveFailed,
		AutoRestartPaused:   m.autoRestartPaused,
	}
	if m.cmd != nil && m.cmd.Process != nil {
		status.PID = m.cmd.Process.Pid
	}
	if !m.startTime.IsZero() {
		status.StartTime = m.startTime.Format(time.RFC3339)
	}
	if !m.exitTime.IsZero() {
		status.ExitTime = m.exitTime.Format(time.RFC3339)
	}
	return status
}

func rewriteKubeconfig(raw []byte, serverAddr string) ([]byte, error) {
	var cfg map[string]interface{}
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, err
	}

	clustersAny, ok := cfg["clusters"]
	if !ok {
		return nil, fmt.Errorf("clusters not found")
	}

	clusters, ok := clustersAny.([]interface{})
	if !ok {
		return nil, fmt.Errorf("clusters has unexpected type")
	}

	for _, item := range clusters {
		clusterItem, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		clusterSpec, ok := clusterItem["cluster"].(map[string]interface{})
		if !ok {
			continue
		}
		delete(clusterSpec, "certificate-authority-data")
		clusterSpec["insecure-skip-tls-verify"] = true
		clusterSpec["server"] = serverAddr
	}

	return yaml.Marshal(cfg)
}

func buildClusterServer(input string) (string, error) {
	s := strings.TrimSpace(input)
	if s == "" {
		return "", fmt.Errorf("empty ones url")
	}
	if !strings.Contains(s, "://") {
		s = "https://" + s
	}

	u, err := url.Parse(s)
	if err != nil {
		return "", err
	}
	host := u.Hostname()
	if host == "" {
		return "", fmt.Errorf("missing hostname")
	}

	return "https://" + host + ":6443", nil
}

func detectOnesURLFromWikiAPI(parent context.Context) (string, []string, error) {
	ns := getenv("WIKI_API_NAMESPACE", "ones")
	podKeyword := getenv("WIKI_API_POD_KEYWORD", "wiki-api")
	domainSuffix := getenv("ONES_DOMAIN_SUFFIX", "k3s-dev.myones.net")
	timeout := getenvDuration("A_ONES_DETECT_TIMEOUT", 30*time.Second)

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	podBytes, err := runKubectl(ctx, "-n", ns, "get", "pods", "-o", "name")
	if err != nil {
		return "", nil, err
	}

	var targetPods []string
	for _, line := range strings.Split(string(podBytes), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// format: pod/<name>
		name := strings.TrimPrefix(line, "pod/")
		if strings.Contains(name, podKeyword) {
			targetPods = append(targetPods, name)
		}
	}
	if len(targetPods) == 0 {
		return "", nil, fmt.Errorf("no pod matched keyword %q in namespace %q", podKeyword, ns)
	}

	var candidates []string
	seen := map[string]bool{}

	for _, pod := range targetPods {
		hosts, e := runKubectl(ctx, "-n", ns, "exec", pod, "--", "cat", "/etc/hosts")
		if e != nil {
			log.Printf("skip pod %s: %v", pod, e)
			continue
		}
		found := extractHostsBySuffix(hosts, domainSuffix)
		for _, h := range found {
			if !seen[h] {
				seen[h] = true
				candidates = append(candidates, h)
			}
		}
	}

	if len(candidates) == 0 {
		return "", nil, errors.New("no ones domain found in /etc/hosts")
	}
	return candidates[0], candidates, nil
}

func extractHostsBySuffix(hosts []byte, suffix string) []string {
	var result []string
	sfx := strings.ToLower(strings.TrimSpace(suffix))
	if sfx == "" {
		return result
	}

	for _, line := range strings.Split(string(hosts), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// remove inline comments
		if i := strings.Index(line, "#"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		for _, host := range fields[1:] {
			host = strings.TrimSpace(host)
			if host == "" {
				continue
			}
			if strings.HasSuffix(strings.ToLower(host), sfx) && !slices.Contains(result, host) {
				result = append(result, host)
			}
		}
	}
	return result
}

func logMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s from=%s cost=%s", r.Method, r.URL.RequestURI(), r.RemoteAddr, time.Since(start))
	})
}

func getenv(key, fallback string) string {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	return v
}

func getenvDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		log.Printf("invalid %s=%q, fallback to %s", key, v, fallback)
		return fallback
	}
	return d
}

func getenvBool(key string, fallback bool) bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if v == "" {
		return fallback
	}
	switch v {
	case "1", "true", "yes", "y", "on":
		return true
	case "0", "false", "no", "n", "off":
		return false
	default:
		log.Printf("invalid %s=%q, fallback to %t", key, v, fallback)
		return fallback
	}
}

func parseBoolQuery(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "y", "on":
		return true
	default:
		return false
	}
}
