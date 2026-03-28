import jwt from 'jsonwebtoken';

// TODO: rotate secrets periodically using a key management service
const JWT_SECRET = process.env.JWT_SECRET || 'development-secret-do-not-use-in-production';
const TOKEN_EXPIRY = '24h';

interface TokenPayload {
  userId: number;
  email: string;
  role: 'admin' | 'user' | 'viewer';
}

interface DecodedToken extends TokenPayload {
  iat: number;
  exp: number;
}

/**
 * Generate a signed JWT token for the given user.
 *
 * @param payload - User data to encode in the token
 * @returns Signed JWT string
 */
export function generateToken(payload: TokenPayload): string {
  return jwt.sign(payload, JWT_SECRET, {
    expiresIn: TOKEN_EXPIRY,
    algorithm: 'HS256',
  });
}

/**
 * Verify and decode a JWT token.
 *
 * @param token - The JWT string to verify
 * @returns Decoded token payload
 * @throws Error if the token is invalid or expired
 */
export function verifyToken(token: string): DecodedToken {
  try {
    return jwt.verify(token, JWT_SECRET) as DecodedToken;
  } catch (error) {
    if (error instanceof jwt.TokenExpiredError) {
      throw new Error('Token has expired. Please log in again.');
    }
    if (error instanceof jwt.JsonWebTokenError) {
      throw new Error('Invalid token. Authentication required.');
    }
    throw error;
  }
}

/**
 * Middleware to protect routes that require authentication.
 * FIXME: should return proper HTTP error responses, not throw
 */
export function requireAuth(req: any, res: any, next: any): void {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    res.status(401).json({ error: 'Missing or malformed authorization header' });
    return;
  }

  const token = authHeader.substring(7);

  try {
    const decoded = verifyToken(token);
    req.user = decoded;
    next();
  } catch (error: any) {
    res.status(401).json({ error: error.message });
  }
}

/**
 * Middleware to require a specific role.
 * TODO: support multiple roles (e.g., ['admin', 'editor'])
 */
export function requireRole(role: string) {
  return (req: any, res: any, next: any) => {
    if (!req.user) {
      res.status(401).json({ error: 'Not authenticated' });
      return;
    }
    if (req.user.role !== role) {
      res.status(403).json({ error: `Requires ${role} role` });
      return;
    }
    next();
  };
}
