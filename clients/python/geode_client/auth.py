"""
Authentication and authorization client for Geode.
"""

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional

from .client import Connection, GeodeError


class AuthError(GeodeError):
    """Raised when authentication fails."""
    pass


@dataclass
class User:
    """Represents a user in the system."""
    id: int
    username: str
    email: str
    is_active: bool
    created_at: datetime
    roles: List[str]
    metadata: Dict[str, str] = None

    def __post_init__(self):
        if self.metadata is None:
            self.metadata = {}


@dataclass
class Role:
    """Represents a role in the RBAC system."""
    id: int
    name: str
    description: str
    permissions: List[str]
    parent_role: Optional[int] = None
    is_system: bool = False
    priority: int = 0


@dataclass
class Permission:
    """Represents a permission in the system."""
    id: int
    name: str
    resource: str
    action: str


@dataclass
class RLSPolicy:
    """Represents a Row-Level Security policy."""
    id: int
    name: str
    table: str
    graph: str
    operation: str
    permissive: bool
    roles: List[int]
    using_expression: str = ""
    check_expression: str = ""
    enabled: bool = True
    data_classification: str = ""
    audit_level: str = ""


@dataclass
class SessionInfo:
    """Contains session information."""
    token: str
    user_id: int
    username: str
    expires_at: datetime
    roles: List[str]


class AuthClient:
    """
    Authentication and authorization client.

    Provides methods for user management, RBAC, and RLS policies.
    """

    def __init__(self, conn: Connection):
        """
        Initialize auth client with a connection.

        Args:
            conn: Active connection to Geode server
        """
        self.conn = conn

    async def login(self, username: str, password: str) -> SessionInfo:
        """
        Authenticate a user and return a session token.

        Args:
            username: Username
            password: Password

        Returns:
            SessionInfo with token and user details

        Raises:
            AuthError: If authentication fails
        """
        req = {
            "type": "AUTH_LOGIN",
            "username": username,
            "password": password,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Login failed")
            raise AuthError(f"Login failed: {message}")

        result = resp.get("result", {})

        return SessionInfo(
            token=result.get("token", ""),
            user_id=int(result.get("user_id", 0)),
            username=result.get("username", ""),
            expires_at=datetime.fromisoformat(result.get("expires_at", "")),
            roles=result.get("roles", []),
        )

    async def logout(self, token: str) -> None:
        """
        Logout and invalidate the session.

        Args:
            token: Session token

        Raises:
            AuthError: If logout fails
        """
        req = {
            "type": "AUTH_LOGOUT",
            "token": token,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Logout failed")
            raise AuthError(f"Logout failed: {message}")

    async def create_user(
        self,
        username: str,
        email: str,
        password: str,
        roles: Optional[List[str]] = None,
        metadata: Optional[Dict[str, str]] = None,
    ) -> User:
        """
        Create a new user.

        Args:
            username: Username
            email: Email address
            password: Password
            roles: List of role names
            metadata: Additional metadata

        Returns:
            Created User object

        Raises:
            AuthError: If user creation fails
        """
        req = {
            "type": "AUTH_CREATE_USER",
            "username": username,
            "email": email,
            "password": password,
        }

        if roles:
            req["roles"] = roles
        if metadata:
            req["metadata"] = metadata

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Create user failed")
            raise AuthError(f"Create user failed: {message}")

        result = resp.get("result", {})
        return self._parse_user(result)

    async def delete_user(self, user_id: int) -> None:
        """
        Delete a user.

        Args:
            user_id: User ID

        Raises:
            AuthError: If deletion fails
        """
        req = {
            "type": "AUTH_DELETE_USER",
            "user_id": user_id,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Delete user failed")
            raise AuthError(f"Delete user failed: {message}")

    async def create_role(
        self,
        name: str,
        description: str,
        permissions: List[str],
    ) -> Role:
        """
        Create a new role.

        Args:
            name: Role name
            description: Role description
            permissions: List of permission names

        Returns:
            Created Role object

        Raises:
            AuthError: If role creation fails
        """
        req = {
            "type": "AUTH_CREATE_ROLE",
            "name": name,
            "description": description,
            "permissions": permissions,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Create role failed")
            raise AuthError(f"Create role failed: {message}")

        result = resp.get("result", {})
        return self._parse_role(result)

    async def grant_permission(self, role_id: int, permission_id: int) -> None:
        """
        Grant a permission to a role.

        Args:
            role_id: Role ID
            permission_id: Permission ID

        Raises:
            AuthError: If grant fails
        """
        req = {
            "type": "AUTH_GRANT_PERMISSION",
            "role_id": role_id,
            "permission_id": permission_id,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Grant permission failed")
            raise AuthError(f"Grant permission failed: {message}")

    async def create_rls_policy(self, policy: RLSPolicy) -> None:
        """
        Create a new Row-Level Security policy.

        Args:
            policy: RLS policy definition

        Raises:
            AuthError: If policy creation fails
        """
        req = {
            "type": "RLS_CREATE_POLICY",
            "name": policy.name,
            "table": policy.table,
            "graph": policy.graph,
            "operation": policy.operation,
            "permissive": policy.permissive,
            "roles": policy.roles,
            "enabled": policy.enabled,
        }

        if policy.using_expression:
            req["using_expr"] = policy.using_expression
        if policy.check_expression:
            req["check_expr"] = policy.check_expression
        if policy.data_classification:
            req["data_classification"] = policy.data_classification
        if policy.audit_level:
            req["audit_level"] = policy.audit_level

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Create policy failed")
            raise AuthError(f"Create policy failed: {message}")

    async def enable_rls_policy(self, policy_id: int, enable: bool = True) -> None:
        """
        Enable or disable an RLS policy.

        Args:
            policy_id: Policy ID
            enable: True to enable, False to disable

        Raises:
            AuthError: If operation fails
        """
        req = {
            "type": "RLS_ENABLE_POLICY",
            "policy_id": policy_id,
            "enabled": enable,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Enable policy failed")
            raise AuthError(f"Enable policy failed: {message}")

    async def check_permission(
        self,
        user_id: int,
        resource: str,
        action: str,
    ) -> bool:
        """
        Check if a user has a specific permission.

        Args:
            user_id: User ID
            resource: Resource name
            action: Action name

        Returns:
            True if user has permission, False otherwise

        Raises:
            AuthError: If check fails
        """
        req = {
            "type": "AUTH_CHECK_PERMISSION",
            "user_id": user_id,
            "resource": resource,
            "action": action,
        }

        await self.conn._write_json(req)
        resp = await self.conn._read_json()

        status = resp.get("status", "")
        if status != "00000":
            message = resp.get("message", "Check permission failed")
            raise AuthError(f"Check permission failed: {message}")

        result = resp.get("result", {})
        return result.get("allowed", False)

    def _parse_user(self, data: Dict[str, Any]) -> User:
        """Parse user data from JSON response."""
        return User(
            id=int(data.get("id", 0)),
            username=data.get("username", ""),
            email=data.get("email", ""),
            is_active=data.get("is_active", False),
            created_at=datetime.fromisoformat(data.get("created_at", "")),
            roles=data.get("roles", []),
            metadata=data.get("metadata", {}),
        )

    def _parse_role(self, data: Dict[str, Any]) -> Role:
        """Parse role data from JSON response."""
        return Role(
            id=int(data.get("id", 0)),
            name=data.get("name", ""),
            description=data.get("description", ""),
            permissions=data.get("permissions", []),
            parent_role=data.get("parent_role"),
            is_system=data.get("is_system", False),
            priority=int(data.get("priority", 0)),
        )
