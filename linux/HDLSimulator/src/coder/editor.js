'use strict';
/* global monaco, Lexer, Keywords, HDLLanguage, Structure, TextUtil, SymbolScanner, Snippets, Templates, NumberInfo, symbolPathAt,
   flattenSymbols, SymbolKinds, Syntax, THEMES, Prefs, symbolColor */
// Monaco editor set-up for Verilog / SystemVerilog / VHDL: colors from the lexer, completions and the
// typing behavior of the Mac app's editor (smart Return, auto `end`, dedent on `end`, placeholders).

const MONACO_LANG = { verilog: 'verilog', systemVerilog: 'systemverilog', vhdl: 'vhdl', plain: 'plaintext' };
const SEM_TYPES = ['hdlKeyword', 'hdlControl', 'hdlType', 'hdlComment', 'hdlString', 'hdlNumber', 'hdlSystem', 'hdlDirective', 'hdlIdent', 'hdlTypeName', 'hdlFuncName'];
const KIND_TO_SEM = { keyword: 0, control: 1, type: 2, comment: 3, string: 4, number: 5, system: 6, directive: 7, attribute: 7, ident: 8, typeName: 9, funcName: 10 };

const HDLEditor = {
  ready: null,
  docFor: null,        // (model) => EditorDocument, set by the Coder
  onGoToDefinition: null,
  instanceModules: null, // () => [{ path, symbol, language }]

  load() {
    if (this.ready) return this.ready;
    this.ready = new Promise((resolve) => {
      self.MonacoEnvironment = {
        getWorkerUrl() {
          return 'data:text/javascript;charset=utf-8,' + encodeURIComponent(
            `self.MonacoEnvironment={baseUrl:'${new URL('../node_modules/monaco-editor/min/', location.href).href}'};` +
            `importScripts('${new URL('../node_modules/monaco-editor/min/vs/base/worker/workerMain.js', location.href).href}');`);
        },
      };
      window.require.config({ paths: { vs: '../node_modules/monaco-editor/min/vs' } });
      window.require(['vs/editor/editor.main'], () => { this.setUp(); resolve(); });
    });
    return this.ready;
  },

  setUp() {
    for (const [hdl, id] of Object.entries(MONACO_LANG)) {
      if (hdl === 'plain') continue;
      monaco.languages.register({ id, extensions: hdl === 'vhdl' ? ['.vhd', '.vhdl'] : (hdl === 'verilog' ? ['.v', '.vh'] : ['.sv', '.svh']) });
      const vhdl = hdl === 'vhdl';
      monaco.languages.setLanguageConfiguration(id, {
        comments: vhdl ? { lineComment: '--', blockComment: ['/*', '*/'] } : { lineComment: '//', blockComment: ['/*', '*/'] },
        brackets: [['(', ')'], ['[', ']'], ['{', '}']],
        autoClosingPairs: [{ open: '(', close: ')' }, { open: '[', close: ']' }, { open: '{', close: '}' }, { open: '"', close: '"', notIn: ['string', 'comment'] }],
        surroundingPairs: [{ open: '(', close: ')' }, { open: '[', close: ']' }, { open: '{', close: '}' }, { open: '"', close: '"' }],
        wordPattern: vhdl ? /[A-Za-z_][\w]*|-?\d+(\.\d+)?/ : /[`$]?[A-Za-z_][\w$]*|-?\d+(\.\d+)?/,
      });
      monaco.languages.setTokensProvider(id, this.lineTokenizer(hdl));
      monaco.languages.registerCompletionItemProvider(id, {
        triggerCharacters: ['$', '`'],
        provideCompletionItems: (model, position, ctx) => this.completions(model, position, ctx),
      });
      monaco.languages.registerDocumentHighlightProvider(id, { provideDocumentHighlights: (model, pos) => this.highlights(model, pos) });
    }
    for (const t of Object.values(THEMES)) monaco.editor.defineTheme('hdl-' + t.id, this.monacoTheme(t));
  },

  // Colors each line with the ported lexer; the state carries an open /* comment */ to the next line.
  lineTokenizer(lang) {
    class St { constructor(c) { this.c = c; } clone() { return new St(this.c); } equals(o) { return !!o && o.c === this.c; } }
    const scope = { keyword: 'keyword', control: 'control', type: 'type', comment: 'comment', string: 'string', number: 'number', system: 'system',
      directive: 'directive', attribute: 'directive', ident: 'identifier', typeName: 'typename', funcName: 'funcname', placeholder: 'identifier', op: 'delimiter' };
    return {
      getInitialState: () => new St(false),
      tokenize: (line, state) => {
        const tokens = [];
        let offset = 0;
        if (state.c) {
          const e = line.indexOf('*/');
          tokens.push({ startIndex: 0, scopes: 'comment' });
          if (e < 0) return { tokens, endState: new St(true) };
          offset = e + 2;
        }
        const rest = line.slice(offset);
        let open = false, pos = 0;
        for (const t of Lexer.lex(rest, lang)) {
          if (t.start > pos) tokens.push({ startIndex: offset + pos, scopes: '' });
          tokens.push({ startIndex: offset + t.start, scopes: scope[t.kind] || '' });
          pos = t.end;
          if (t.kind === 'comment' && rest.startsWith('/*', t.start) && !(t.length >= 4 && rest.slice(t.end - 2, t.end) === '*/')) open = true;
        }
        if (pos < rest.length) tokens.push({ startIndex: offset + pos, scopes: '' });
        if (!tokens.length) tokens.push({ startIndex: 0, scopes: '' });
        return { tokens, endState: new St(open) };
      },
    };
  },

  monarch(vhdl) {
    if (vhdl) {
      return {
        ignoreCase: true,
        keywords: [...Keywords.vhdlKeywords], control: [...Keywords.vhdlControl], types: [...Keywords.vhdlTypes],
        tokenizer: {
          root: [
            [/--.*$/, 'comment'], [/\/\*/, 'comment', '@comment'], [/"([^"]|"")*"/, 'string'],
            [/[a-z_][\w]*/, { cases: { '@control': 'control', '@types': 'type', '@keywords': 'keyword', '@default': '' } }],
            [/\d[\d_]*(\.\d+)?([eE][-+]?\d+)?/, 'number'],
          ],
          comment: [[/\*\//, 'comment', '@pop'], [/./, 'comment']],
        },
      };
    }
    return {
      keywords: [...Keywords.verilogKeywords], control: [...Keywords.verilogControl], types: [...Keywords.verilogTypes],
      tokenizer: {
        root: [
          [/\/\/.*$/, 'comment'], [/\/\*/, 'comment', '@comment'], [/"([^"\\]|\\.)*"?/, 'string'],
          [/`[A-Za-z_]\w*/, 'directive'], [/\$[A-Za-z_][\w$]*/, 'system'],
          [/[A-Za-z_][\w$]*/, { cases: { '@control': 'control', '@types': 'type', '@keywords': 'keyword', '@default': '' } }],
          [/(\d[\d_]*)?'[sS]?[bodhBODH]\s*[0-9a-fA-FxXzZ?_]+|\d[\d_]*(\.\d+)?([eE][-+]?\d+)?/, 'number'],
        ],
        comment: [[/\*\//, 'comment', '@pop'], [/./, 'comment']],
      },
    };
  },

  monacoTheme(t) {
    const s = Syntax.colors(t);
    const hex = (c) => c.replace('#', '');
    const rules = [
      { token: 'comment', foreground: hex(s.comment) }, { token: 'string', foreground: hex(s.string) },
      { token: 'keyword', foreground: hex(s.keyword) }, { token: 'control', foreground: hex(s.control) },
      { token: 'type', foreground: hex(s.type) }, { token: 'number', foreground: hex(s.number) },
      { token: 'directive', foreground: hex(s.directive) }, { token: 'system', foreground: hex(s.system) },
      { token: 'identifier', foreground: hex(t.editorFG) }, { token: 'typename', foreground: hex(s.type) },
      { token: 'funcname', foreground: hex(s.system) }, { token: 'delimiter', foreground: hex(t.editorFG) },
      { token: 'hdlKeyword', foreground: hex(s.keyword) }, { token: 'hdlControl', foreground: hex(s.control) },
      { token: 'hdlType', foreground: hex(s.type) }, { token: 'hdlComment', foreground: hex(s.comment) },
      { token: 'hdlString', foreground: hex(s.string) }, { token: 'hdlNumber', foreground: hex(s.number) },
      { token: 'hdlSystem', foreground: hex(s.system) }, { token: 'hdlDirective', foreground: hex(s.directive) },
      { token: 'hdlIdent', foreground: hex(t.editorFG) }, { token: 'hdlTypeName', foreground: hex(s.type) },
      { token: 'hdlFuncName', foreground: hex(s.system) },
    ];
    const alpha = (c, a) => { if (c.startsWith('rgba')) return c; const n = Math.round(a * 255).toString(16).padStart(2, '0'); return c + n; };
    const rgbaToHex = (c) => {
      const m = /rgba\((\d+),(\d+),(\d+),([\d.]+)\)/.exec(c.replace(/\s/g, ''));
      if (!m) return c;
      return '#' + [m[1], m[2], m[3]].map((x) => (+x).toString(16).padStart(2, '0')).join('') + Math.round(+m[4] * 255).toString(16).padStart(2, '0');
    };
    return {
      base: t.dark ? 'vs-dark' : 'vs', inherit: true, rules,
      colors: {
        'editor.background': t.editor, 'editor.foreground': t.editorFG,
        'editorLineNumber.foreground': t.gutterFG, 'editorLineNumber.activeForeground': t.gutterActiveFG,
        'editor.selectionBackground': t.selection, 'editor.inactiveSelectionBackground': alpha(t.selection, 0.6),
        'editor.lineHighlightBackground': rgbaToHex(t.lineHighlight), 'editor.lineHighlightBorder': '#00000000',
        'editorCursor.foreground': t.caret,
        'editorIndentGuide.background1': rgbaToHex(t.indentGuide), 'editorIndentGuide.activeBackground1': rgbaToHex(t.indentGuide.replace(/[\d.]+\)$/, (m) => (parseFloat(m) * 2.2).toFixed(2) + ')')),
        'editorWidget.background': t.widgetBG, 'editorWidget.border': t.widgetBorder,
        'editorSuggestWidget.background': t.widgetBG, 'editorSuggestWidget.border': t.widgetBorder,
        'editorSuggestWidget.selectedBackground': t.listSelection, 'editorHoverWidget.background': t.widgetBG,
        'input.background': t.inputBG, 'input.border': t.inputBorder, 'focusBorder': t.focusBorder,
        'editorError.foreground': t.error, 'editorWarning.foreground': t.warning, 'editorInfo.foreground': t.info,
        'editorGutter.background': t.editor, 'minimap.background': t.editor,
        'scrollbarSlider.background': t.dark ? '#79797966' : '#64646466',
        'editorBracketMatch.background': t.dark ? '#88888852' : '#77777738', 'editorBracketMatch.border': '#00000000',
        'editor.wordHighlightBackground': t.dark ? '#57575780' : '#57575740', 'editor.wordHighlightStrongBackground': t.dark ? '#57575780' : '#57575740',
      },
    };
  },

  semanticTokens(model) {
    const doc = this.docFor && this.docFor(model);
    const toks = doc ? doc.tokens() : Lexer.lex(model.getValue(), 'verilog');
    const text = model.getValue();
    const data = [];
    let prevLine = 0, prevChar = 0;
    for (const t of toks) {
      const type = KIND_TO_SEM[t.kind];
      if (type == null) continue;
      // Split tokens that span lines (block comments) into one entry per line.
      let start = t.start, line = t.line;
      const end = t.end;
      while (start < end) {
        let nl = text.indexOf('\n', start);
        if (nl < 0 || nl > end) nl = end;
        const lineStart = text.lastIndexOf('\n', start - 1) + 1;
        const ch = start - lineStart;
        const len = nl - start;
        if (len > 0) {
          data.push(line - prevLine, line === prevLine ? ch - prevChar : ch, len, type, 0);
          prevLine = line; prevChar = ch;
        }
        start = nl + 1;
        line++;
      }
    }
    return { data: new Uint32Array(data) };
  },

  highlights(model, pos) {
    const doc = this.docFor && this.docFor(model);
    if (!doc) return [];
    const off = model.getOffsetAt(pos);
    const toks = doc.tokens();
    const k = doc.tokenIndexTouching(off);
    if (k == null) return [];
    const t = toks[k];
    if (!['ident', 'typeName', 'funcName'].includes(t.kind)) return [];
    const text = model.getValue();
    const vhdl = doc.language === 'vhdl';
    const norm = (s) => (vhdl ? s.toLowerCase() : s);
    const word = norm(text.slice(t.start, t.end));
    const out = [];
    for (const o of toks) {
      if (o.length !== t.length || !['ident', 'typeName', 'funcName'].includes(o.kind)) continue;
      if (norm(text.slice(o.start, o.end)) !== word) continue;
      const a = model.getPositionAt(o.start), b = model.getPositionAt(o.end);
      out.push({ range: new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column), kind: monaco.languages.DocumentHighlightKind.Text });
      if (out.length >= 400) break;
    }
    return out.length > 1 ? out : [];
  },

  completions(model, position, ctx) {
    const doc = this.docFor && this.docFor(model);
    if (!doc) return { suggestions: [] };
    const text = model.getValue();
    const caret = model.getOffsetAt(position);
    let start = caret;
    while (start > 0) {
      const c = text.charCodeAt(start - 1);
      if (Lexer.isIdChar(c) || c === 96) start--; else break;
      if (c === 96 || c === 36) break;
    }
    const prefix = text.slice(start, caret);
    const explicit = ctx.triggerKind === monaco.languages.CompletionTriggerKind.Invoke;
    if (!explicit) {
      const special = prefix.startsWith('$') || prefix.startsWith('`');
      if (prefix.length < (special ? 1 : 2) && ctx.triggerKind !== monaco.languages.CompletionTriggerKind.TriggerCharacter) return { suggestions: [] };
      if (doc.isInCommentOrString(caret)) return { suggestions: [] };
      if (/^\d/.test(prefix)) return { suggestions: [] };
    }
    const sp = model.getPositionAt(start);
    const range = new monaco.Range(sp.lineNumber, sp.column, position.lineNumber, position.column);
    const lineStart = text.lastIndexOf('\n', start - 1) + 1;
    const atLineStart = text.slice(lineStart, start).trim() === '';
    const K = monaco.languages.CompletionItemKind;
    const S = monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet;
    const out = [];
    const add = (label, detail, kind, insertText, rank, extra = {}) => out.push(Object.assign({ label, detail, kind, insertText, range, sortText: String(9 - rank) + label.toLowerCase() }, extra));
    if (prefix.startsWith('$')) {
      const noArgs = ['$time', '$stime', '$realtime', '$finish', '$stop', '$random', '$urandom'];
      const nextIsParen = text[caret] === '(';
      for (const t of Keywords.systemTasks) {
        const needs = !noArgs.includes(t) && !nextIsParen;
        add(t, 'system task', K.Function, needs ? t.replace(/\$/g, '\\$') + '(${1:args})' : t.replace(/\$/g, '\\$'), 0, { insertTextRules: S });
      }
    } else if (prefix.startsWith('`')) {
      for (const d of Keywords.directives) add(d, 'directive', K.Keyword, d, 0);
      const re = /`define\s+([A-Za-z_][A-Za-z0-9_]*)/g;
      let m;
      while ((m = re.exec(text))) add('`' + m[1], 'macro', K.Constant, '`' + m[1], 0);
    } else {
      const seen = new Set();
      const words = doc.identifiers(caret);
      for (const [w, k] of words) {
        if (seen.has(w)) continue;
        seen.add(w);
        add(w, k ? SymbolKinds.label(k) : '', k ? this.kindFor(k) : K.Variable, w, 3);
      }
      const kw = doc.language === 'vhdl' ? new Set([...Keywords.vhdlAll, ...Keywords.vhdlTypes]) : Keywords.verilogAll;
      for (const w of kw) if (!seen.has(w)) add(w, 'keyword', K.Keyword, w, 0);
      for (const s of Snippets.available(doc.language)) {
        add(s.prefix, s.title, K.Snippet, Snippets.toMonaco(Snippets.expand(s, '', doc.indentUnit)), 1, { insertTextRules: S, documentation: s.body.replace(/\t/g, '    ') });
      }
      for (const d of (this.instanceModules ? this.instanceModules() : [])) {
        const m = d.symbol;
        if (!['module', 'entity', 'interface'].includes(m.kind)) continue;
        if (atLineStart) {
          const tpl = Templates.instance(m, doc.language, doc.indentUnit);
          const body = tpl.replace(/[$}\\]/g, '\\$&').replace(`u_${m.name}`, '${1:u_' + m.name + '}');
          add(m.name, `instantiate ${SymbolKinds.label(m.kind)}`, K.Module, body, 2, { insertTextRules: S });
        } else if (!seen.has(m.name)) add(m.name, SymbolKinds.label(m.kind), K.Module, m.name, 2);
      }
    }
    return { suggestions: out.slice(0, 2000) };
  },

  kindFor(k) {
    const K = monaco.languages.CompletionItemKind;
    return { module: K.Module, entity: K.Module, interface: K.Interface, package: K.Module, klass: K.Class, port: K.Field,
      param: K.Constant, constant: K.Constant, signal: K.Variable, instance: K.Reference, process: K.Event, function: K.Function,
      task: K.Method, type: K.TypeParameter }[k] || K.Variable;
  },

  // ---------------------------------------------------------------- Editor options

  options() {
    const fontSize = Prefs.get('editor.fontSize');
    const name = Prefs.get('editor.fontName');
    return {
      fontSize,
      fontFamily: (name ? `"${name}", ` : '') + '"Cascadia Mono", "Cascadia Code", Consolas, "SF Mono", Menlo, monospace',
      lineHeight: Math.ceil(fontSize * 1.45),
      wordWrap: Prefs.get('editor.wordWrap') ? 'on' : 'off',
      autoClosingBrackets: Prefs.get('editor.autoClose') ? 'languageDefined' : 'never',
      autoClosingQuotes: Prefs.get('editor.autoClose') ? 'languageDefined' : 'never',
      quickSuggestions: Prefs.get('editor.suggest') ? { other: true, comments: false, strings: false } : false,
      renderLineHighlight: Prefs.get('editor.highlightLine') ? 'line' : 'none',
      guides: { indentation: Prefs.get('editor.indentGuides'), bracketPairs: false },
      renderWhitespace: Prefs.get('editor.showInvisibles') ? 'all' : 'none',
      minimap: { enabled: Prefs.get('editor.minimap') },
    };
  },

  create(host) {
    const ed = monaco.editor.create(host, Object.assign({
      model: null, automaticLayout: true, theme: 'hdl-' + Prefs.get('themeID'),
      'semanticHighlighting.enabled': false, 'bracketPairColorization.enabled': false, detectIndentation: false, scrollBeyondLastLine: true,
      bracketPairColorization: { enabled: false }, matchBrackets: 'always', occurrencesHighlight: 'singleFile',
      suggestOnTriggerCharacters: true, acceptSuggestionOnEnter: 'smart', tabCompletion: 'off', wordBasedSuggestions: 'off',
      snippetSuggestions: 'inline', fixedOverflowWidgets: true, mouseWheelZoom: false, contextmenu: false,
      smoothScrolling: false, cursorBlinking: 'blink', padding: { top: 6 }, stickyScroll: { enabled: false },
      unicodeHighlight: { ambiguousCharacters: false }, links: false, colorDecorators: false, lightbulb: { enabled: 'off' },
      hover: { enabled: true, delay: 500 }, autoIndent: 'keep', formatOnType: false, autoSurround: 'languageDefined',
      scrollbar: { verticalScrollbarSize: 12, horizontalScrollbarSize: 12, useShadows: false },
    }, this.options()));
    return ed;
  },
};

// ---------------------------------------------------------------- Typing behavior (port of CodeTextView)

const BLOCK_CLOSERS = {
  begin: 'end', fork: 'join', generate: 'endgenerate', case: 'endcase', casez: 'endcase', casex: 'endcase', randcase: 'endcase',
  function: 'endfunction', task: 'endtask', module: 'endmodule', class: 'endclass', interface: 'endinterface', package: 'endpackage',
  program: 'endprogram', specify: 'endspecify', covergroup: 'endgroup', clocking: 'endclocking',
};

const Typing = {
  // Return: indentation, closer on its own line inside empty brackets, auto `end`. Returns true if handled.
  newline(doc, ed) {
    const model = ed.getModel();
    const sels = ed.getSelections();
    if (!model || !sels || sels.length !== 1) return false;
    const lang = doc.language;
    const text = model.getValue();
    const selA = model.getOffsetAt(sels[0].getStartPosition()), selB = model.getOffsetAt(sels[0].getEndPosition());
    const lineStart = text.lastIndexOf('\n', selA - 1) + 1;
    let lineEnd = text.indexOf('\n', selA);
    if (lineEnd < 0) lineEnd = text.length;
    const before = text.slice(lineStart, selA);
    const after = selB <= lineEnd ? text.slice(selB, lineEnd) : '';
    const fullLine = text.slice(lineStart, lineEnd);
    const indent = TextUtil.leadingWhitespace(before ? before : fullLine);
    const unit = doc.indentUnit;
    const code = TextUtil.stripComment(before, lang);
    const trimmedCode = code.trim();
    const afterTrim = after.replace(/^[ \t]*/, '');
    const prevCh = trimmedCode[trimmedCode.length - 1];
    const n = afterTrim[0];
    const replace = (a, b, ins, caret) => {
      const pa = model.getPositionAt(a), pb = model.getPositionAt(b);
      ed.pushUndoStop();
      ed.executeEdits('hdl', [{ range: new monaco.Range(pa.lineNumber, pa.column, pb.lineNumber, pb.column), text: ins, forceMoveMarkers: true }]);
      const pc = model.getPositionAt(caret);
      ed.setSelection(new monaco.Selection(pc.lineNumber, pc.column, pc.lineNumber, pc.column));
      ed.pushUndoStop();
      ed.revealPosition(pc);
    };
    if (prevCh && n && ((prevCh === '(' && n === ')') || (prevCh === '[' && n === ']') || (prevCh === '{' && n === '}'))) {
      const skip = after.length - afterTrim.length;
      const ins = '\n' + indent + unit + '\n' + indent;
      replace(selA, selB + skip, ins, selA + 1 + (indent + unit).length);
      return true;
    }
    let newIndent = indent;
    const verilog = HDLLanguage.isVerilogFamily(lang);
    if (TextUtil.increasesIndent(code, lang)) newIndent += unit;
    else if (verilog && trimmedCode.startsWith(')') && trimmedCode.endsWith(';')) {
      const header = Typing.headerInfo(doc, lineStart + indent.length);
      if (header) {
        newIndent = header.indent + unit;
        const closer = BLOCK_CLOSERS[header.word];
        if (Prefs.get('editor.autoEnd') && !doc.pairs().has(header.token) && closer && after.trim() === '') {
          const ins = '\n' + newIndent + '\n' + header.indent + closer;
          replace(selA, selB + after.length, ins, selA + 1 + newIndent.length);
          return true;
        }
      }
    } else if (verilog && trimmedCode.endsWith(';')) {
      let l = doc.lineIndex(lineStart) - 1;
      while (l >= 0 && doc.lineText(l).trim() === '') l--;
      if (l >= 0) {
        const prev = doc.lineText(l);
        const prevLead = TextUtil.leadingWhitespace(prev);
        if (TextUtil.isSingleStatementHead(TextUtil.stripComment(prev, lang)) && TextUtil.indentWidth(prevLead, doc.tabSize) < TextUtil.indentWidth(indent, doc.tabSize)) newIndent = prevLead;
      }
    }
    let ra = selA, rb = selB;
    if (before.trim() === '' && before) ra = lineStart;
    const skipAfter = after.length - afterTrim.length;
    rb += skipAfter;
    if (Prefs.get('editor.autoEnd') && verilog && afterTrim.trim() === '') {
      const closer = Typing.closerToInsert(doc, trimmedCode, lineStart, lineEnd);
      if (closer) {
        const ins = '\n' + newIndent + '\n' + indent + closer;
        replace(ra, rb, ins, ra + 1 + newIndent.length);
        return true;
      }
    }
    const ins = '\n' + newIndent;
    replace(ra, rb, ins, ra + ins.length);
    return true;
  },

  headerInfo(doc, off) {
    const toks = doc.tokens(), text = doc.text;
    const k = doc.tokenIndexTouching(off);
    if (k == null || toks[k].start !== off) return null;
    const m = doc.pairs().get(k);
    if (m == null) return null;
    for (let j = m - 1; j >= 0; j--) {
      const t = toks[j];
      if (t.kind === 'op' && text.charCodeAt(t.start) === 59) return null;
      if (t.kind === 'keyword' || t.kind === 'control') {
        const w = Lexer.string(text, t);
        if (Structure.headerOpeners.has(w)) return { indent: TextUtil.leadingWhitespace(doc.lineText(doc.lineIndex(t.start))), word: w, token: j };
        if (['begin', 'end', 'assign', 'always', 'initial'].includes(w)) return null;
      }
    }
    return null;
  },

  closerToInsert(doc, code, lineStart, lineEnd) {
    const lw = TextUtil.lastWord(code), fw = TextUtil.firstWord(code);
    let opener = null;
    if (['begin', 'fork', 'generate', 'specify'].includes(lw)) opener = lw;
    else if (['case', 'casez', 'casex', 'randcase'].includes(fw) && code.endsWith(')')) opener = fw;
    else if ((fw === 'unique' || fw === 'priority' || fw === 'unique0') && code.endsWith(')')) opener = ['case', 'casez', 'casex'].find((c) => code.includes(c + ' ') || code.includes(c + '(')) || null;
    else if (['function', 'task', 'module', 'class', 'interface', 'package', 'program', 'covergroup'].includes(fw) && code.endsWith(';')) opener = fw;
    else if (fw === 'virtual' && code.endsWith(';') && code.includes('class ')) opener = 'class';
    else if (['static', 'automatic'].includes(fw) && code.endsWith(';')) opener = code.includes('function') ? 'function' : (code.includes('task') ? 'task' : null);
    const closer = opener && BLOCK_CLOSERS[opener];
    if (!closer) return null;
    const toks = doc.tokens(), text = doc.text;
    let found = null;
    for (let k = Lexer.indexAt(toks, lineStart); k < toks.length && toks[k].start < lineEnd + 1; k++) {
      const t = toks[k];
      if ((t.kind === 'keyword' || t.kind === 'control') && Lexer.string(text, t) === opener) found = k;
    }
    if (found == null) return null;
    if (doc.pairs().has(found)) {
      const closers = Structure.verilogOpeners[opener] || [closer];
      let opens = 0, closes = 0;
      for (const t of toks) {
        if (t.kind !== 'keyword' && t.kind !== 'control') continue;
        const w = Lexer.string(text, t);
        const o = Structure.verilogOpeners[w];
        if (o && closers.every((c) => o.includes(c))) opens++;
        else if (closers.includes(w)) closes++;
      }
      if (opens <= closes) return null;
    }
    return closer;
  },

  // After typing a letter: `end`, `endcase`… (and `begin` after an `if (…)` line) move to their opener's indentation.
  afterType(doc, ed, ch) {
    const model = ed.getModel();
    const sel = ed.getSelection();
    if (!model || !sel || !sel.isEmpty()) return;
    const lang = doc.language;
    const text = model.getValue();
    const off = model.getOffsetAt(sel.getStartPosition());
    const lineStart = text.lastIndexOf('\n', off - 1) + 1;
    let lineEnd = text.indexOf('\n', off);
    if (lineEnd < 0) lineEnd = text.length;
    const line = text.slice(lineStart, lineEnd).replace(/\r$/, '');
    if (text.slice(off, lineEnd).trim() !== '') return;
    const trimmed = line.trim();
    const lead = TextUtil.leadingWhitespace(line);
    let target = null;
    if (/[A-Za-z0-9_]/.test(ch)) {
      if (HDLLanguage.isVerilogFamily(lang)) {
        if (Structure.verilogClosers.has(trimmed)) {
          const k = doc.tokenIndexTouching(lineStart + lead.length);
          const m = k != null ? doc.pairs().get(k) : null;
          if (m != null) target = TextUtil.leadingWhitespace(doc.lineText(doc.lineIndex(doc.tokens()[m].start)));
        } else if (trimmed === 'begin') {
          let l = doc.lineIndex(lineStart) - 1;
          while (l >= 0 && doc.lineText(l).trim() === '') l--;
          if (l >= 0) {
            const prev = doc.lineText(l);
            if (TextUtil.isSingleStatementHead(TextUtil.stripComment(prev, lang))) target = TextUtil.leadingWhitespace(prev);
          }
        }
      } else if (lang === 'vhdl') {
        const w = trimmed.toLowerCase();
        if (['end', 'begin', 'else', 'elsif', 'when'].includes(w)) {
          let l = doc.lineIndex(lineStart) - 1;
          while (l >= 0 && doc.lineText(l).trim() === '') l--;
          if (l >= 0) {
            const prev = doc.lineText(l);
            const prevLead = TextUtil.leadingWhitespace(prev);
            const c = TextUtil.stripComment(prev, lang);
            if (TextUtil.increasesIndent(c, lang) && !(w === 'when' && c.toLowerCase().endsWith('=>'))) target = prevLead;
            else target = TextUtil.makeIndent(Math.max(0, TextUtil.indentWidth(prevLead, doc.tabSize) - doc.tabSize), doc.tabSize, doc.useSpaces);
          }
        }
      }
    } else if (')}]'.includes(ch) && (trimmed.length === 1 || trimmed === ');')) {
      const k = doc.tokenIndexTouching(lineStart + lead.length);
      const toks = doc.tokens();
      const m = k != null && toks[k].start === lineStart + lead.length ? doc.pairs().get(k) : null;
      if (m != null && doc.lineIndex(toks[m].start) !== doc.lineIndex(lineStart)) target = TextUtil.leadingWhitespace(doc.lineText(doc.lineIndex(toks[m].start)));
      if (target != null && TextUtil.indentWidth(target, doc.tabSize) === TextUtil.indentWidth(lead, doc.tabSize)) target = null;
      if (target != null) { Typing.setLead(ed, model, lineStart, lead, target); return; }
      return;
    }
    if (target == null || target === lead || TextUtil.indentWidth(target, doc.tabSize) >= TextUtil.indentWidth(lead, doc.tabSize)) return;
    Typing.setLead(ed, model, lineStart, lead, target);
  },

  setLead(ed, model, lineStart, lead, target) {
    const p = model.getPositionAt(lineStart);
    const sel = ed.getSelection();
    const fromEnd = model.getLineMaxColumn(p.lineNumber) - sel.positionColumn;
    ed.executeEdits('hdl-indent', [{ range: new monaco.Range(p.lineNumber, 1, p.lineNumber, 1 + lead.length), text: target }]);
    const col = model.getLineMaxColumn(p.lineNumber) - fromEnd;
    ed.setSelection(new monaco.Selection(p.lineNumber, col, p.lineNumber, col));
  },

  // Tab / Shift+Tab: next / previous <#placeholder#>.
  selectPlaceholder(ed, forward) {
    const model = ed.getModel();
    const text = model.getValue();
    if (!text.includes('<#')) return false;
    const sel = ed.getSelection();
    const a = model.getOffsetAt(sel.getStartPosition()), b = model.getOffsetAt(sel.getEndPosition());
    const re = /<#[^#\n]*#>/g;
    const all = [];
    let m;
    while ((m = re.exec(text))) all.push([m.index, m.index + m[0].length]);
    if (!all.length) return false;
    let found = null;
    if (forward) found = all.find((r) => r[0] >= b) || all.find((r) => r[1] <= a);
    else found = [...all].reverse().find((r) => r[1] <= a) || [...all].reverse().find((r) => r[0] >= b);
    if (!found || (found[0] === a && found[1] === b)) return false;
    const pa = model.getPositionAt(found[0]), pb = model.getPositionAt(found[1]);
    ed.setSelection(new monaco.Selection(pa.lineNumber, pa.column, pb.lineNumber, pb.column));
    ed.revealRangeInCenterIfOutsideViewport(new monaco.Range(pa.lineNumber, pa.column, pb.lineNumber, pb.column));
    return true;
  },
};

if (typeof module !== 'undefined') module.exports = { HDLEditor, Typing, MONACO_LANG };
