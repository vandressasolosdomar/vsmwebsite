# Site + Blog | Vandressa Solos do Mar Advocacia

Site institucional (landing page estática) com blog Jekyll integrado, publicado via GitHub Pages no domínio `advsolosdomar.com.br`.

## Estrutura

```
index.html          Landing page (estática, não é processada pelo Jekyll)
404.html            Página de erro
_config.yml         Configuração do Jekyll (SEO, permalinks, plugins)
_layouts/           Layouts do blog (default.html, post.html)
_includes/          Parciais (date-pt.html formata datas em português)
_posts/             Artigos do blog (Markdown com front matter)
blog/index.html     Página de listagem do blog (/blog/)
robots.txt          Aponta para o sitemap
Gemfile             Ambiente idêntico ao GitHub Pages para build local
```

## Como publicar um novo post

Crie um arquivo em `_posts/` com o nome `AAAA-MM-DD-slug-do-post.md`:

```markdown
---
title: "Título do post"
description: "Resumo de até 160 caracteres, usado no Google e nos cards."
date: 2026-07-10
categories: [INSS]
tags: [palavra-chave, outra]
---

Conteúdo em Markdown...
```

O post fica disponível em `https://advsolosdomar.com.br/blog/slug-do-post/`.
Ao fazer push para a branch principal, o GitHub Pages compila o Jekyll automaticamente. Não é preciso build manual.

## SEO já configurado

- `jekyll-seo-tag`: title, description, canonical, Open Graph e JSON-LD (BlogPosting) em cada post;
- `jekyll-sitemap`: gera `/sitemap.xml` (referenciado em `robots.txt`);
- `jekyll-feed`: gera `/feed.xml` (RSS);
- Dados estruturados `LegalService` na landing page;
- URLs limpas: `/blog/nome-do-post/`.

Após o primeiro deploy, cadastre o site no [Google Search Console](https://search.google.com/search-console) e envie o sitemap `https://advsolosdomar.com.br/sitemap.xml`.

## Build local (opcional)

Com Ruby 2.7+ e Bundler:

```bash
bundle install
bundle exec jekyll serve
# abre http://localhost:4000
```

Alternativa rápida com gems globais (sem Gemfile):

```bash
gem install jekyll jekyll-seo-tag jekyll-sitemap jekyll-feed
JEKYLL_NO_BUNDLER_REQUIRE=true jekyll serve
```

## Observações

- A landing (`index.html`) não tem front matter, então o Jekyll a copia sem alterações;
- Os ícones do site são SVGs inline (estilo traço). No wizard, ficam no objeto `ICO` dentro do script de `index.html`;
- O arquivo `CNAME` mantém o domínio customizado. Não remova.
