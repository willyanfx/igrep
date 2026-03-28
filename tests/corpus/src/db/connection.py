"""Database connection pool management.

This module provides a thread-safe connection pool for PostgreSQL
using psycopg2. All queries should go through the pool to avoid
connection exhaustion under load.

TODO: add connection health checks and automatic reconnection
"""

import os
import threading
from contextlib import contextmanager
from typing import Optional

# FIXME: these should come from a config file, not environment variables
DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://localhost:5432/app")
MAX_CONNECTIONS = int(os.environ.get("DB_MAX_CONNECTIONS", "20"))
CONNECTION_TIMEOUT = int(os.environ.get("DB_TIMEOUT", "30"))


class ConnectionPool:
    """Thread-safe database connection pool.

    Usage:
        pool = ConnectionPool(DATABASE_URL, max_size=20)
        with pool.connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT * FROM users WHERE id = %s", (user_id,))
    """

    _instance: Optional["ConnectionPool"] = None
    _lock = threading.Lock()

    def __init__(self, dsn: str, max_size: int = 10):
        self.dsn = dsn
        self.max_size = max_size
        self._pool = []
        self._in_use = 0
        self._condition = threading.Condition(self._lock)

    @classmethod
    def get_instance(cls) -> "ConnectionPool":
        """Singleton access to the global connection pool."""
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:
                    cls._instance = cls(DATABASE_URL, MAX_CONNECTIONS)
        return cls._instance

    @contextmanager
    def connection(self):
        """Acquire a connection from the pool."""
        conn = self._acquire()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            self._release(conn)

    def _acquire(self):
        """Get a connection, blocking if the pool is exhausted."""
        with self._condition:
            while not self._pool and self._in_use >= self.max_size:
                # HACK: should have a configurable wait timeout here
                self._condition.wait(timeout=CONNECTION_TIMEOUT)
            if self._pool:
                conn = self._pool.pop()
            else:
                conn = self._create_connection()
            self._in_use += 1
            return conn

    def _release(self, conn):
        """Return a connection to the pool."""
        with self._condition:
            self._in_use -= 1
            self._pool.append(conn)
            self._condition.notify()

    def _create_connection(self):
        """Create a new database connection."""
        # In real code this would call psycopg2.connect(self.dsn)
        return MockConnection(self.dsn)

    def close_all(self):
        """Close all connections in the pool. Call on shutdown."""
        with self._lock:
            for conn in self._pool:
                conn.close()
            self._pool.clear()


class MockConnection:
    """Stand-in for a real database connection during testing."""

    def __init__(self, dsn: str):
        self.dsn = dsn
        self.closed = False

    def cursor(self):
        return MockCursor()

    def commit(self):
        pass

    def rollback(self):
        pass

    def close(self):
        self.closed = True


class MockCursor:
    def execute(self, query: str, params=None):
        pass

    def fetchone(self):
        return None

    def fetchall(self):
        return []
