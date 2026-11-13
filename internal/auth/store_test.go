package auth

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/oauth2"

	"github.com/Mag1cFall/Antigravity2API/internal/antigravity"
)

// TestStoreAddWithDeviceAfterWorkingDirectoryRemoved 模拟服务启动后工作目录被移除：
// OAuth 已成功取得 token，保存账户时仍应写到启动时解析的账户目录。
func TestStoreAddWithDeviceAfterWorkingDirectoryRemoved(t *testing.T) {
	working := filepath.Join(t.TempDir(), "data")
	if err := os.Mkdir(working, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(working)
	store, err := Open("auth", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(working); err != nil {
		t.Fatal(err)
	}
	claims := base64.RawURLEncoding.EncodeToString([]byte(`{"email":"login@example.com"}`))
	token := (&oauth2.Token{AccessToken: "test-access", RefreshToken: "test-refresh"}).WithExtra(map[string]any{
		"id_token": "header." + claims + ".signature",
	})
	account, err := store.AddWithDevice(context.Background(), token, antigravity.Device{})
	if err != nil {
		t.Fatalf("OAuth 已完成，保存账户失败: %v", err)
	}
	if _, err := os.Stat(filepath.Join(working, "auth", account.ID, tokenFile)); err != nil {
		t.Fatalf("账户 token 没有持久化到原目录: %v", err)
	}
}

// TestOpenCreatesAccountDirectory 验证首次启动即创建私有账户目录。
func TestOpenCreatesAccountDirectory(t *testing.T) {
	root := t.TempDir()
	t.Chdir(root)
	store, err := Open("auth", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(store.dir) {
		t.Fatalf("账户目录仍是相对路径: %s", store.dir)
	}
	info, err := os.Stat(store.dir)
	if err != nil || !info.IsDir() {
		t.Fatalf("首次启动未创建账户目录: %v", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("账户目录允许其他用户访问: %v", info.Mode())
	}
}

// TestOpenRejectsInvalidDirectory 验证配置错误在登录前报出。
func TestOpenRejectsInvalidDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(path, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(filepath.Join(path, "auth"), nil); err == nil {
		t.Fatal("错误账户目录没有在打开时被拒绝")
	}
}

// TestStoreDirectoryRemainsStableAfterChdir 验证进程切换目录不会把凭据写到其他位置。
func TestStoreDirectoryRemainsStableAfterChdir(t *testing.T) {
	initial := t.TempDir()
	t.Chdir(initial)
	store, err := Open("auth", nil)
	if err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if err := os.Chdir(other); err != nil {
		t.Fatal(err)
	}
	account := &Account{ID: "stable@example.com", Email: "stable@example.com", Enabled: true}
	if err := store.Save(account); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(initial, "auth", account.ID, accountFile)); err != nil {
		t.Fatalf("账户没有保存在启动时的目录: %v", err)
	}
	if _, err := os.Stat(filepath.Join(other, "auth")); !os.IsNotExist(err) {
		t.Fatalf("账户错误写入新的工作目录: %v", err)
	}
}
