// Short link service — Go (Gin) + MySQL (via ProxySQL) + Redis (via Sentinel)
//
// Endpoints:
//   POST /api/shorten   {"url": "https://example.com"}  -> {"short_code": "dX7vQ", "short_url": "..."}
//   GET  /:code          -> 301 Redirect -> original URL
//   GET  /health         -> {"status": "ok", "version": "v1.0.N"}   (liveness / readiness probe)
package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	_ "github.com/go-sql-driver/mysql"
)

// ── Build info ─────────────────────────────────────────────────
// AppVersion — set at build time via -ldflags or updated for CI/CD verification.
// Pushed by GitHub Actions as v1.0.{run_number}, detected by FluxCD ImagePolicy.
const AppVersion = "v1.0.1"

// ── Configuration ──────────────────────────────────────────────

type Config struct {
	HTTPPort         string
	MySQLHost        string
	MySQLPort        string
	MySQLUser        string
	MySQLPassword    string
	MySQLDatabase    string
	RedisSentinel    string
	RedisMasterName  string
	CacheTTL         time.Duration
}

func loadConfig() Config {
	return Config{
		HTTPPort:        getEnv("APP_PORT", "8080"),
		MySQLHost:       getEnv("MYSQL_HOST", "proxysql.data-layer.svc.cluster.local"),
		MySQLPort:       getEnv("MYSQL_PORT", "6033"),
		MySQLUser:       getEnv("MYSQL_USER", "shortlink"),
		MySQLPassword:   os.Getenv("MYSQL_PASSWORD"),
		MySQLDatabase:   getEnv("MYSQL_DATABASE", "shortlink"),
		RedisSentinel:   getEnv("REDIS_SENTINEL", "sentinel.data-layer.svc.cluster.local:26379"),
		RedisMasterName: getEnv("REDIS_MASTER_NAME", "mymaster"),
		CacheTTL:        24 * time.Hour,
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ── Base62 short code encoding ─────────────────────────────────

const base62Chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

func encodeBase62(n int64) string {
	if n == 0 {
		return "0"
	}
	result := ""
	for n > 0 {
		result = string(base62Chars[n%62]) + result
		n /= 62
	}
	return result
}

// ── Storage layer ──────────────────────────────────────────────

type Storage struct {
	db  *sql.DB
	rdb *redis.Client
	ttl time.Duration
}

func newStorage(cfg Config) (*Storage, error) {
	// MySQL via ProxySQL (read/write splitting is transparent to the app)
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&timeout=5s&readTimeout=5s&writeTimeout=5s",
		cfg.MySQLUser, cfg.MySQLPassword, cfg.MySQLHost, cfg.MySQLPort, cfg.MySQLDatabase)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("mysql open: %w", err)
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("mysql ping: %w", err)
	}
	log.Println("[storage] MySQL connected via ProxySQL:", cfg.MySQLHost+":"+cfg.MySQLPort)

	// Redis via Sentinel (automatic failover)
	rdb := redis.NewFailoverClient(&redis.FailoverOptions{
		MasterName:    cfg.RedisMasterName,
		SentinelAddrs: []string{cfg.RedisSentinel},
		DB:            0,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping: %w", err)
	}
	log.Println("[storage] Redis connected via Sentinel (master:", cfg.RedisMasterName, ")")

	return &Storage{db: db, rdb: rdb, ttl: cfg.CacheTTL}, nil
}

func (s *Storage) Close() {
	if s.db != nil {
		s.db.Close()
	}
	if s.rdb != nil {
		s.rdb.Close()
	}
}

// CreateShortLink inserts a new URL mapping and returns the short code.
// Strategy: INSERT -> get auto-increment ID -> encode to Base62 -> UPDATE.
// This avoids collisions and demonstrates ProxySQL read/write routing.
func (s *Storage) CreateShortLink(ctx context.Context, originalURL string) (string, error) {
	// Step 1: INSERT (ProxySQL routes to MySQL Master — hostgroup 1)
	result, err := s.db.ExecContext(ctx,
		"INSERT INTO url_mapping (short_code, original_url) VALUES ('', ?)",
		originalURL,
	)
	if err != nil {
		return "", fmt.Errorf("insert: %w", err)
	}

	id, err := result.LastInsertId()
	if err != nil {
		return "", fmt.Errorf("last_insert_id: %w", err)
	}

	// Step 2: Encode ID to Base62 short code
	code := encodeBase62(id)

	// Step 3: UPDATE with short code (ProxySQL routes to MySQL Master — hostgroup 1)
	_, err = s.db.ExecContext(ctx,
		"UPDATE url_mapping SET short_code = ? WHERE id = ?",
		code, id,
	)
	if err != nil {
		return "", fmt.Errorf("update: %w", err)
	}

	// Step 4: Cache in Redis (Sentinel routes to current Master)
	err = s.rdb.Set(ctx, "short:"+code, originalURL, s.ttl).Err()
	if err != nil {
		log.Printf("[storage] Redis cache SET failed (non-fatal): %v", err)
	}

	log.Printf("[shorten] id=%d code=%s url=%s", id, code, originalURL)
	return code, nil
}

// ResolveShortLink looks up the original URL for a short code.
// Strategy: check Redis cache first, fall back to MySQL on cache miss.
func (s *Storage) ResolveShortLink(ctx context.Context, code string) (string, error) {
	// Step 1: Check Redis cache
	cached, err := s.rdb.Get(ctx, "short:"+code).Result()
	if err == nil {
		log.Printf("[resolve] cache hit code=%s", code)
		return cached, nil
	}
	if !errors.Is(err, redis.Nil) {
		log.Printf("[resolve] Redis GET error (non-fatal): %v", err)
	}

	// Step 2: Cache miss — query MySQL (ProxySQL routes SELECT to Slave — hostgroup 2)
	var originalURL string
	err = s.db.QueryRowContext(ctx,
		"SELECT original_url FROM url_mapping WHERE short_code = ?",
		code,
	).Scan(&originalURL)

	if err == sql.ErrNoRows {
		return "", nil // not found
	}
	if err != nil {
		return "", fmt.Errorf("select: %w", err)
	}

	// Step 3: Backfill cache
	err = s.rdb.Set(ctx, "short:"+code, originalURL, s.ttl).Err()
	if err != nil {
		log.Printf("[resolve] Redis cache backfill failed (non-fatal): %v", err)
	}

	log.Printf("[resolve] cache miss code=%s (backfilled)", code)
	return originalURL, nil
}

// HealthCheck verifies MySQL and Redis connectivity.
func (s *Storage) HealthCheck(ctx context.Context) error {
	if err := s.db.PingContext(ctx); err != nil {
		return fmt.Errorf("mysql: %w", err)
	}
	if err := s.rdb.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("redis: %w", err)
	}
	return nil
}

// ── HTTP handlers ──────────────────────────────────────────────

type Handler struct {
	store *Storage
}

type ShortenRequest struct {
	URL string `json:"url" binding:"required"`
}

type ShortenResponse struct {
	ShortCode string `json:"short_code"`
	ShortURL  string `json:"short_url"`
}

func (h *Handler) Health(c *gin.Context) {
	ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Second)
	defer cancel()

	if err := h.store.HealthCheck(ctx); err != nil {
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "error", "version": AppVersion, "detail": err.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "version": AppVersion})
}

func (h *Handler) Shorten(c *gin.Context) {
	var req ShortenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "missing or invalid 'url' field"})
		return
	}

	// Validate URL
	parsed, err := url.ParseRequestURI(req.URL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "url must be a valid http(s) URL"})
		return
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), 5*time.Second)
	defer cancel()

	code, err := h.store.CreateShortLink(ctx, req.URL)
	if err != nil {
		log.Printf("[shorten] error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create short link"})
		return
	}

	// Build short URL from request host
	scheme := "http"
	if c.Request.TLS != nil {
		scheme = "https"
	}
	shortURL := fmt.Sprintf("%s://%s/%s", scheme, c.Request.Host, code)

	c.JSON(http.StatusOK, ShortenResponse{
		ShortCode: code,
		ShortURL:  shortURL,
	})
}

func (h *Handler) Redirect(c *gin.Context) {
	code := c.Param("code")

	ctx, cancel := context.WithTimeout(c.Request.Context(), 5*time.Second)
	defer cancel()

	originalURL, err := h.store.ResolveShortLink(ctx, code)
	if err != nil {
		log.Printf("[redirect] error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "internal error"})
		return
	}

	if originalURL == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "short link not found"})
		return
	}

	c.Redirect(http.StatusMovedPermanently, originalURL)
}

// ── Main ───────────────────────────────────────────────────────

func main() {
	cfg := loadConfig()

	if cfg.MySQLPassword == "" {
		log.Fatal("MYSQL_PASSWORD environment variable is required")
	}

	// Initialize storage (MySQL + Redis)
	store, err := newStorage(cfg)
	if err != nil {
		log.Fatalf("Failed to initialize storage: %v", err)
	}
	defer store.Close()
	log.Println("[main] Storage initialized successfully")

	// Setup Gin router
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	handler := &Handler{store: store}

	r.GET("/health", handler.Health)
	r.POST("/api/shorten", handler.Shorten)
	r.GET("/:code", handler.Redirect)

	// HTTP server with graceful shutdown
	srv := &http.Server{
		Addr:         ":" + cfg.HTTPPort,
		Handler:      r,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("[main] Short link service listening on :%s", cfg.HTTPPort)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("[main] Shutting down server...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}
	log.Println("[main] Server stopped gracefully")
}
