import React, { useState, useCallback, useRef, useEffect } from 'react';

interface SearchResult {
  file: string;
  line: number;
  content: string;
  matchStart: number;
  matchEnd: number;
}

interface SearchBarProps {
  onSearch: (query: string) => Promise<SearchResult[]>;
  placeholder?: string;
  debounceMs?: number;
}

/**
 * SearchBar component with debounced live search.
 *
 * TODO: add keyboard navigation for results (up/down/enter)
 * TODO: highlight matching text in results
 * FIXME: results flash briefly when typing fast due to race conditions
 */
export const SearchBar: React.FC<SearchBarProps> = ({
  onSearch,
  placeholder = 'Search codebase...',
  debounceMs = 300,
}) => {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const timerRef = useRef<NodeJS.Timeout | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const handleSearch = useCallback(
    async (searchQuery: string) => {
      if (searchQuery.length < 2) {
        setResults([]);
        return;
      }

      // Cancel previous in-flight request
      if (abortRef.current) {
        abortRef.current.abort();
      }
      abortRef.current = new AbortController();

      setLoading(true);
      setError(null);

      try {
        const searchResults = await onSearch(searchQuery);
        setResults(searchResults);
      } catch (err: any) {
        if (err.name !== 'AbortError') {
          setError(err.message || 'Search failed');
          console.error('Search error:', err);
        }
      } finally {
        setLoading(false);
      }
    },
    [onSearch]
  );

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const value = e.target.value;
      setQuery(value);

      if (timerRef.current) {
        clearTimeout(timerRef.current);
      }

      timerRef.current = setTimeout(() => {
        handleSearch(value);
      }, debounceMs);
    },
    [handleSearch, debounceMs]
  );

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
      if (abortRef.current) abortRef.current.abort();
    };
  }, []);

  return (
    <div className="search-container">
      <div className="search-input-wrapper">
        <input
          type="text"
          value={query}
          onChange={handleInputChange}
          placeholder={placeholder}
          className="search-input"
          aria-label="Search"
        />
        {loading && <span className="search-spinner" />}
      </div>

      {error && (
        <div className="search-error" role="alert">
          {error}
        </div>
      )}

      {results.length > 0 && (
        <ul className="search-results" role="listbox">
          {results.map((result, idx) => (
            <li key={`${result.file}:${result.line}:${idx}`} role="option">
              <span className="result-file">{result.file}</span>
              <span className="result-line">:{result.line}</span>
              <pre className="result-content">{result.content}</pre>
            </li>
          ))}
        </ul>
      )}

      {!loading && query.length >= 2 && results.length === 0 && !error && (
        <div className="search-empty">No results found for &quot;{query}&quot;</div>
      )}
    </div>
  );
};

export default SearchBar;
