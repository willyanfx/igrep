/**
 * FitFoods Theme JavaScript
 *
 * TODO: split into lazy-loaded modules per section
 * TODO: add cart AJAX API integration
 * FIXME: variant selector doesn't update URL on mobile Safari
 */

(function () {
  'use strict';

  // ── Cart API ──────────────────────────────────────────────────────

  class CartAPI {
    constructor() {
      this.baseUrl = window.routes || {};
    }

    async addItem(variantId, quantity = 1) {
      const response = await fetch(this.baseUrl.cart_add_url || '/cart/add.js', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          items: [{ id: variantId, quantity }],
        }),
      });

      if (!response.ok) {
        throw new Error(`Failed to add item: ${response.status}`);
      }

      return response.json();
    }

    async updateItem(key, quantity) {
      const response = await fetch(this.baseUrl.cart_change_url || '/cart/change.js', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: key, quantity }),
      });

      return response.json();
    }

    async getCart() {
      const response = await fetch('/cart.js');
      return response.json();
    }
  }

  // ── Variant Selector ──────────────────────────────────────────────

  class VariantSelector {
    constructor(container) {
      this.container = container;
      this.productData = JSON.parse(
        container.querySelector('[type="application/json"]')?.textContent || '{}'
      );
      this.options = container.querySelectorAll('.product__option-select');
      this.bindEvents();
    }

    bindEvents() {
      this.options.forEach((select) => {
        select.addEventListener('change', () => this.onVariantChange());
      });
    }

    onVariantChange() {
      const selectedOptions = Array.from(this.options).map((s) => s.value);
      const variant = this.productData.variants?.find((v) =>
        v.options.every((opt, i) => opt === selectedOptions[i])
      );

      if (variant) {
        this.updatePrice(variant);
        this.updateButton(variant);
        this.updateURL(variant);
      }
    }

    updatePrice(variant) {
      const priceEl = this.container.querySelector('.product__price');
      if (priceEl) {
        priceEl.textContent = this.formatMoney(variant.price);
      }
    }

    updateButton(variant) {
      const button = this.container.querySelector('.product__submit');
      const idInput = this.container.querySelector('input[name="id"]');

      if (idInput) idInput.value = variant.id;

      if (button) {
        button.disabled = !variant.available;
        button.textContent = variant.available ? 'Add to cart' : 'Sold out';
      }
    }

    // FIXME: doesn't work in Safari when inside a modal
    updateURL(variant) {
      if (!variant) return;
      const url = new URL(window.location);
      url.searchParams.set('variant', variant.id);
      window.history.replaceState({}, '', url);
    }

    formatMoney(cents) {
      return new Intl.NumberFormat('en-CA', {
        style: 'currency',
        currency: 'CAD',
      }).format(cents / 100);
    }
  }

  // ── Predictive Search ─────────────────────────────────────────────

  class PredictiveSearch {
    constructor(input, resultsContainer) {
      this.input = input;
      this.results = resultsContainer;
      this.abortController = null;
      this.debounceTimer = null;

      this.input.addEventListener('input', () => this.onInput());
    }

    onInput() {
      clearTimeout(this.debounceTimer);
      const query = this.input.value.trim();

      if (query.length < 2) {
        this.results.innerHTML = '';
        return;
      }

      this.debounceTimer = setTimeout(() => this.search(query), 300);
    }

    async search(query) {
      if (this.abortController) this.abortController.abort();
      this.abortController = new AbortController();

      try {
        const url = `${window.routes?.predictive_search_url || '/search/suggest'}?q=${encodeURIComponent(query)}&resources[type]=product&resources[limit]=6`;

        const response = await fetch(url, {
          signal: this.abortController.signal,
        });

        if (!response.ok) return;

        const data = await response.json();
        this.renderResults(data);
      } catch (err) {
        if (err.name !== 'AbortError') {
          console.error('Predictive search error:', err);
        }
      }
    }

    renderResults(data) {
      const products = data.resources?.results?.products || [];

      if (products.length === 0) {
        this.results.innerHTML = '<p class="predictive-search__empty">No results</p>';
        return;
      }

      this.results.innerHTML = products
        .map(
          (p) => `
          <a href="${p.url}" class="predictive-search__item">
            <img src="${p.image}" alt="${p.title}" width="50" height="50" loading="lazy">
            <div>
              <span class="predictive-search__title">${p.title}</span>
              <span class="predictive-search__price">${p.price}</span>
            </div>
          </a>
        `
        )
        .join('');
    }
  }

  // ── Init ──────────────────────────────────────────────────────────

  document.addEventListener('DOMContentLoaded', () => {
    window.cart = new CartAPI();

    const productForm = document.querySelector('[data-product-form]');
    if (productForm) {
      new VariantSelector(productForm.closest('.product'));
    }

    const searchInput = document.querySelector('[data-predictive-search-input]');
    const searchResults = document.querySelector('[data-predictive-search-results]');
    if (searchInput && searchResults) {
      new PredictiveSearch(searchInput, searchResults);
    }
  });
})();
