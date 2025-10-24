package gql

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// AuthClient provides authentication and authorization methods
type AuthClient struct {
	conn *Conn
}

// User represents a user in the system
type User struct {
	ID        int64             `json:"id"`
	Username  string            `json:"username"`
	Email     string            `json:"email"`
	IsActive  bool              `json:"is_active"`
	CreatedAt time.Time         `json:"created_at"`
	Roles     []string          `json:"roles"`
	Metadata  map[string]string `json:"metadata,omitempty"`
}

// Role represents a role in the RBAC system
type Role struct {
	ID          int64    `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Permissions []string `json:"permissions"`
	ParentRole  *int64   `json:"parent_role,omitempty"`
	IsSystem    bool     `json:"is_system"`
	Priority    int      `json:"priority"`
}

// Permission represents a permission in the system
type Permission struct {
	ID       int64  `json:"id"`
	Name     string `json:"name"`
	Resource string `json:"resource"`
	Action   string `json:"action"`
}

// RLSPolicy represents a Row-Level Security policy
type RLSPolicy struct {
	ID                 int64   `json:"id"`
	Name               string  `json:"name"`
	Table              string  `json:"table"`
	Graph              string  `json:"graph"`
	Operation          string  `json:"operation"`
	Permissive         bool    `json:"permissive"`
	Roles              []int64 `json:"roles"`
	UsingExpression    string  `json:"using_expr,omitempty"`
	CheckExpression    string  `json:"check_expr,omitempty"`
	Enabled            bool    `json:"enabled"`
	DataClassification string  `json:"data_classification,omitempty"`
	AuditLevel         string  `json:"audit_level"`
}

// SessionInfo contains session information
type SessionInfo struct {
	Token     string    `json:"token"`
	UserID    int64     `json:"user_id"`
	Username  string    `json:"username"`
	ExpiresAt time.Time `json:"expires_at"`
	Roles     []string  `json:"roles"`
}

// NewAuthClient creates a new authentication client
func (c *Conn) Auth() *AuthClient {
	return &AuthClient{conn: c}
}

// Login authenticates a user and returns a session token
func (a *AuthClient) Login(ctx context.Context, username, password string) (*SessionInfo, error) {
	req := map[string]any{
		"type":     "AUTH_LOGIN",
		"username": username,
		"password": password,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return nil, fmt.Errorf("failed to send login request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to read login response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return nil, fmt.Errorf("login failed: %s", msg)
		}
		return nil, fmt.Errorf("login failed with status: %s", status)
	}

	result, ok := resp["result"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("invalid response format")
	}

	session := &SessionInfo{}
	if token, ok := result["token"].(string); ok {
		session.Token = token
	}
	if userID, ok := result["user_id"].(float64); ok {
		session.UserID = int64(userID)
	}
	if username, ok := result["username"].(string); ok {
		session.Username = username
	}
	if expiresAt, ok := result["expires_at"].(string); ok {
		if t, err := time.Parse(time.RFC3339, expiresAt); err == nil {
			session.ExpiresAt = t
		}
	}
	if roles, ok := result["roles"].([]any); ok {
		for _, r := range roles {
			if role, ok := r.(string); ok {
				session.Roles = append(session.Roles, role)
			}
		}
	}

	return session, nil
}

// Logout invalidates the current session
func (a *AuthClient) Logout(ctx context.Context, token string) error {
	req := map[string]any{
		"type":  "AUTH_LOGOUT",
		"token": token,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return fmt.Errorf("failed to send logout request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return fmt.Errorf("failed to read logout response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return fmt.Errorf("logout failed: %s", msg)
		}
		return fmt.Errorf("logout failed with status: %s", status)
	}

	return nil
}

// CreateUser creates a new user
func (a *AuthClient) CreateUser(ctx context.Context, username, email, password string, roles []string, metadata map[string]string) (*User, error) {
	req := map[string]any{
		"type":     "AUTH_CREATE_USER",
		"username": username,
		"email":    email,
		"password": password,
	}
	if len(roles) > 0 {
		req["roles"] = roles
	}
	if len(metadata) > 0 {
		req["metadata"] = metadata
	}

	if err := a.conn.writeJSON(req); err != nil {
		return nil, fmt.Errorf("failed to send create user request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return nil, fmt.Errorf("create user failed: %s", msg)
		}
		return nil, fmt.Errorf("create user failed with status: %s", status)
	}

	// Parse user from response
	result, _ := resp["result"].(map[string]any)
	user := &User{}
	if data, err := json.Marshal(result); err == nil {
		_ = json.Unmarshal(data, user)
	}

	return user, nil
}

// DeleteUser deletes a user
func (a *AuthClient) DeleteUser(ctx context.Context, userID int64) error {
	req := map[string]any{
		"type":    "AUTH_DELETE_USER",
		"user_id": userID,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return fmt.Errorf("failed to send delete user request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return fmt.Errorf("delete user failed: %s", msg)
		}
		return fmt.Errorf("delete user failed with status: %s", status)
	}

	return nil
}

// CreateRole creates a new role
func (a *AuthClient) CreateRole(ctx context.Context, name, description string, permissions []string) (*Role, error) {
	req := map[string]any{
		"type":        "AUTH_CREATE_ROLE",
		"name":        name,
		"description": description,
		"permissions": permissions,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return nil, fmt.Errorf("failed to send create role request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return nil, fmt.Errorf("create role failed: %s", msg)
		}
		return nil, fmt.Errorf("create role failed with status: %s", status)
	}

	result, _ := resp["result"].(map[string]any)
	role := &Role{}
	if data, err := json.Marshal(result); err == nil {
		_ = json.Unmarshal(data, role)
	}

	return role, nil
}

// GrantPermission grants a permission to a role
func (a *AuthClient) GrantPermission(ctx context.Context, roleID int64, permissionID int64) error {
	req := map[string]any{
		"type":          "AUTH_GRANT_PERMISSION",
		"role_id":       roleID,
		"permission_id": permissionID,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return fmt.Errorf("failed to send grant permission request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return fmt.Errorf("grant permission failed: %s", msg)
		}
		return fmt.Errorf("grant permission failed with status: %s", status)
	}

	return nil
}

// CreateRLSPolicy creates a new Row-Level Security policy
func (a *AuthClient) CreateRLSPolicy(ctx context.Context, policy *RLSPolicy) error {
	req := map[string]any{
		"type":       "RLS_CREATE_POLICY",
		"name":       policy.Name,
		"table":      policy.Table,
		"graph":      policy.Graph,
		"operation":  policy.Operation,
		"permissive": policy.Permissive,
		"roles":      policy.Roles,
		"enabled":    policy.Enabled,
	}

	if policy.UsingExpression != "" {
		req["using_expr"] = policy.UsingExpression
	}
	if policy.CheckExpression != "" {
		req["check_expr"] = policy.CheckExpression
	}
	if policy.DataClassification != "" {
		req["data_classification"] = policy.DataClassification
	}
	if policy.AuditLevel != "" {
		req["audit_level"] = policy.AuditLevel
	}

	if err := a.conn.writeJSON(req); err != nil {
		return fmt.Errorf("failed to send create policy request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return fmt.Errorf("create policy failed: %s", msg)
		}
		return fmt.Errorf("create policy failed with status: %s", status)
	}

	return nil
}

// EnableRLSPolicy enables or disables an RLS policy
func (a *AuthClient) EnableRLSPolicy(ctx context.Context, policyID int64, enable bool) error {
	req := map[string]any{
		"type":      "RLS_ENABLE_POLICY",
		"policy_id": policyID,
		"enabled":   enable,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return fmt.Errorf("failed to send enable policy request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return fmt.Errorf("enable policy failed: %s", msg)
		}
		return fmt.Errorf("enable policy failed with status: %s", status)
	}

	return nil
}

// CheckPermission checks if a user has a specific permission
func (a *AuthClient) CheckPermission(ctx context.Context, userID int64, resource string, action string) (bool, error) {
	req := map[string]any{
		"type":     "AUTH_CHECK_PERMISSION",
		"user_id":  userID,
		"resource": resource,
		"action":   action,
	}

	if err := a.conn.writeJSON(req); err != nil {
		return false, fmt.Errorf("failed to send check permission request: %w", err)
	}

	resp, err := a.conn.readJSON(ctx)
	if err != nil {
		return false, fmt.Errorf("failed to read response: %w", err)
	}

	if status, ok := resp["status"].(string); ok && status != "00000" {
		if msg, ok := resp["message"].(string); ok {
			return false, fmt.Errorf("check permission failed: %s", msg)
		}
		return false, fmt.Errorf("check permission failed with status: %s", status)
	}

	result, ok := resp["result"].(map[string]any)
	if !ok {
		return false, fmt.Errorf("invalid response format")
	}

	allowed, _ := result["allowed"].(bool)
	return allowed, nil
}
