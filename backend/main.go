package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
)

var db *sql.DB

// Item 是 CRUD 的主体资源
type Item struct {
	ID          int64  `json:"id"`
	Name        string `json:"name"`
	Category    string `json:"category"`
	Status      string `json:"status"`
	Description string `json:"description"`
	CreatedAt   string `json:"createdAt"`
	UpdatedAt   string `json:"updatedAt"`
}

type itemPayload struct {
	Name        string `json:"name"`
	Category    string `json:"category"`
	Status      string `json:"status"`
	Description string `json:"description"`
}

var allowedStatus = map[string]bool{"pending": true, "doing": true, "done": true}

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

func dsn() string {
	return fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4&loc=Local&timeout=5s",
		env("DB_USER", "root"),
		env("DB_PASSWORD", ""),
		env("DB_HOST", "127.0.0.1"),
		env("DB_PORT", "3306"),
		env("DB_NAME", "crud"),
	)
}

// connectDB 在数据库尚未就绪时持续重试，适配容器启动顺序不确定的场景
func connectDB() error {
	deadline := time.Now().Add(120 * time.Second)
	for attempt := 1; ; attempt++ {
		conn, err := sql.Open("mysql", dsn())
		if err == nil {
			conn.SetMaxOpenConns(10)
			conn.SetMaxIdleConns(5)
			conn.SetConnMaxLifetime(30 * time.Minute)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			err = conn.PingContext(ctx)
			cancel()
			if err == nil {
				db = conn
				log.Printf("database connected (attempt %d)", attempt)
				return nil
			}
			conn.Close()
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("database unreachable after %d attempts: %w", attempt, err)
		}
		log.Printf("database not ready (attempt %d): %v -> retry in 3s", attempt, err)
		time.Sleep(3 * time.Second)
	}
}

func migrate() error {
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS items (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(120) NOT NULL,
  category    VARCHAR(60)  NOT NULL DEFAULT 'general',
  status      VARCHAR(20)  NOT NULL DEFAULT 'pending',
  description VARCHAR(500) NOT NULL DEFAULT '',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;`)
	if err != nil {
		return err
	}
	if env("DB_SEED", "true") == "true" {
		var count int
		if err := db.QueryRow("SELECT COUNT(*) FROM items").Scan(&count); err != nil {
			return err
		}
		if count == 0 {
			seed := []struct{ name, category, status, desc string }{
				{"设计 API 契约", "backend", "done", "定义 REST 接口与返回结构"},
				{"实现 CRUD 页面", "frontend", "doing", "Vue 3 列表 / 表单 / 删除"},
				{"接入 ArgoCD 同步", "devops", "pending", "Git 变更自动同步到集群"},
			}
			for _, s := range seed {
				if _, err := db.Exec(
					"INSERT INTO items (name, category, status, description) VALUES (?, ?, ?, ?)",
					s.name, s.category, s.status, s.desc); err != nil {
					return err
				}
			}
			log.Printf("seeded %d demo items", len(seed))
		}
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s (%s)", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
	})
}

func health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "degraded", "db": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "db": "up", "time": time.Now().Format(time.RFC3339)})
}

const selectCols = "id, name, category, status, description, created_at, updated_at"

func scanItem(sc interface{ Scan(...any) error }) (Item, error) {
	var it Item
	var created, updated time.Time
	if err := sc.Scan(&it.ID, &it.Name, &it.Category, &it.Status, &it.Description, &created, &updated); err != nil {
		return it, err
	}
	it.CreatedAt = created.Format("2006-01-02 15:04:05")
	it.UpdatedAt = updated.Format("2006-01-02 15:04:05")
	return it, nil
}

func listItems(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	status := strings.TrimSpace(r.URL.Query().Get("status"))

	sqlStr := "SELECT " + selectCols + " FROM items"
	var where []string
	var args []any
	if q != "" {
		where = append(where, "(name LIKE ? OR description LIKE ?)")
		like := "%" + q + "%"
		args = append(args, like, like)
	}
	if status != "" {
		where = append(where, "status = ?")
		args = append(args, status)
	}
	if len(where) > 0 {
		sqlStr += " WHERE " + strings.Join(where, " AND ")
	}
	sqlStr += " ORDER BY id DESC"

	rows, err := db.QueryContext(r.Context(), sqlStr, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	items := make([]Item, 0, 16)
	for rows.Next() {
		it, err := scanItem(rows)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, items)
}

func getItem(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	row := db.QueryRowContext(r.Context(), "SELECT "+selectCols+" FROM items WHERE id = ?", id)
	it, err := scanItem(row)
	if errors.Is(err, sql.ErrNoRows) {
		writeErr(w, http.StatusNotFound, "item not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, it)
}

func decodePayload(r *http.Request) (itemPayload, error) {
	var p itemPayload
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return p, fmt.Errorf("invalid json body: %w", err)
	}
	p.Name = strings.TrimSpace(p.Name)
	p.Category = strings.TrimSpace(p.Category)
	p.Status = strings.TrimSpace(p.Status)
	p.Description = strings.TrimSpace(p.Description)

	if p.Name == "" {
		return p, errors.New("name is required")
	}
	if len([]rune(p.Name)) > 120 {
		return p, errors.New("name too long (max 120)")
	}
	if len([]rune(p.Description)) > 500 {
		return p, errors.New("description too long (max 500)")
	}
	if p.Category == "" {
		p.Category = "general"
	}
	if p.Status == "" {
		p.Status = "pending"
	}
	if !allowedStatus[p.Status] {
		return p, fmt.Errorf("status must be one of pending/doing/done, got %q", p.Status)
	}
	return p, nil
}

func createItem(w http.ResponseWriter, r *http.Request) {
	p, err := decodePayload(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	res, err := db.ExecContext(r.Context(),
		"INSERT INTO items (name, category, status, description) VALUES (?, ?, ?, ?)",
		p.Name, p.Category, p.Status, p.Description)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	id, _ := res.LastInsertId()
	row := db.QueryRowContext(r.Context(), "SELECT "+selectCols+" FROM items WHERE id = ?", id)
	it, err := scanItem(row)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, it)
}

func updateItem(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	p, err := decodePayload(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	res, err := db.ExecContext(r.Context(),
		"UPDATE items SET name = ?, category = ?, status = ?, description = ? WHERE id = ?",
		p.Name, p.Category, p.Status, p.Description, id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		// MySQL 在值未变化时也可能返回 0，需要再查一次确认是否存在
		var exists int
		if err := db.QueryRowContext(r.Context(), "SELECT 1 FROM items WHERE id = ?", id).Scan(&exists); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeErr(w, http.StatusNotFound, "item not found")
				return
			}
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	row := db.QueryRowContext(r.Context(), "SELECT "+selectCols+" FROM items WHERE id = ?", id)
	it, err := scanItem(row)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, it)
}

func deleteItem(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	res, err := db.ExecContext(r.Context(), "DELETE FROM items WHERE id = ?", id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		writeErr(w, http.StatusNotFound, "item not found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"deleted": id})
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.Printf("crud-backend starting (version=%s)", env("APP_VERSION", "dev"))

	if err := connectDB(); err != nil {
		log.Fatalf("startup failed: %v", err)
	}
	if err := migrate(); err != nil {
		log.Fatalf("migration failed: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", health)
	mux.HandleFunc("GET /api/items", listItems)
	mux.HandleFunc("POST /api/items", createItem)
	mux.HandleFunc("GET /api/items/{id}", getItem)
	mux.HandleFunc("PUT /api/items/{id}", updateItem)
	mux.HandleFunc("DELETE /api/items/{id}", deleteItem)

	port := env("PORT", "8080")
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           logging(cors(mux)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server error: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	log.Println("shutting down ...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
	if db != nil {
		db.Close()
	}
	log.Println("bye")
}
