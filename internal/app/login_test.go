package app

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/Mag1cFall/Antigravity2API/internal/antigravity"
	"github.com/Mag1cFall/Antigravity2API/internal/auth"
	"github.com/Mag1cFall/Antigravity2API/internal/config"
)

// TestCodeLoginAfterWorkingDirectoryRemoved 经过真实的授权码提交、PKCE token 交换与账户保存，
// 验证服务工作目录失效后，已成功的 Google 授权不会因相对 auth 路径变成“登录失败”。
func TestCodeLoginAfterWorkingDirectoryRemoved(t *testing.T) {
	working := filepath.Join(t.TempDir(), "data")
	if err := os.Mkdir(working, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(working)
	store, err := auth.Open("auth", nil)
	if err != nil {
		t.Fatal(err)
	}
	var exchanges atomic.Int32
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		exchanges.Add(1)
		if err := r.ParseForm(); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if r.Form.Get("code") != "test-code" || r.Form.Get("code_verifier") == "" ||
			r.Form.Get("redirect_uri") != "https://antigravity.google/oauth-callback" {
			t.Error("授权码、PKCE 或回调地址错误")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		claims := base64.RawURLEncoding.EncodeToString([]byte(`{"email":"code-login@example.com"}`))
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"access_token": "test-access", "refresh_token": "test-refresh", "token_type": "Bearer", "expires_in": 3600,
			"id_token": "header." + claims + ".signature",
		})
	}))
	defer endpoint.Close()
	previous := antigravity.OAuthConfig
	t.Cleanup(func() { antigravity.OAuthConfig = previous })
	antigravity.OAuthConfig.ClientID, antigravity.OAuthConfig.ClientSecret = "test-client", "test-secret"
	antigravity.OAuthConfig.Endpoint.AuthURL = endpoint.URL + "/authorize"
	antigravity.OAuthConfig.Endpoint.TokenURL = endpoint.URL + "/token"
	s := newAuthServer(config.Default())
	s.ctx, s.events, s.refreshes = t.Context(), newHub(), make(chan struct{}, 1)
	s.deps.Store = store
	s.logins = &logins{server: s, items: map[string]*login{}}
	state, err := s.logins.start(t.Context(), "code")
	if err != nil {
		t.Fatal(err)
	}
	authorization, err := url.Parse(state.URL)
	if err != nil || authorization.Query().Get("code_challenge_method") != "S256" {
		t.Fatal("登录链接缺少 S256 PKCE")
	}
	if err := os.RemoveAll(working); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/logins/"+state.ID+"/code", strings.NewReader(`{"code":"test-code"}`))
	request.SetPathValue("id", state.ID)
	response := httptest.NewRecorder()
	s.submitLoginCode(response, request)
	var result loginState
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if exchanges.Load() != 1 {
		t.Fatalf("OAuth token 交换次数=%d", exchanges.Load())
	}
	if response.Code != http.StatusOK || result.State != "completed" {
		t.Fatalf("OAuth 已成功，提交授权码仍失败: HTTP %d, state=%s, error=%s", response.Code, result.State, result.Error)
	}
	if _, err := os.Stat(filepath.Join(working, "auth", result.Account, "token.json")); err != nil {
		t.Fatalf("账户凭据未持久化: %v", err)
	}
}
