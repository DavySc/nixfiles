;;; kitty-markdown.el --- markdown editing  -*- lexical-binding: t; -*-

;;; Commentary:

;; Writing markdown should feel like a word processor that happens to be
;; plain text:
;;
;;   - prose in a proportional font, centred in a comfortable column, with
;;     scaled headings and aligned tables, code staying monospaced
;;   - markup (**, #, `, link targets) hidden everywhere except on the line
;;     you are editing, where it is shown so nothing is ever ambiguous
;;   - lists, checkboxes and tables continue and align as you type
;;   - images shown inline, pasted from the clipboard with SPC m i p
;;   - code blocks highlighted in their own language and editable in a
;;     buffer of that mode (SPC m e)
;;   - links, headings and references completed and checked by marksman
;;   - live preview and export through pandoc
;;
;; `.md' opens in `gfm-mode' (GitHub flavoured, with task lists and tables).

;;; Code:

(require 'kitty-lib)
(require 'elec-pair)

(defvar markdown-hide-markup)
(defvar markdown-mode-map)
(defvar doom-modeline-enable-word-count)
(defvar doom-modeline-continuous-word-count-modes)

(add-to-list 'auto-mode-alist '("\\.md\\'" . gfm-mode))
(add-to-list 'auto-mode-alist '("\\.markdown\\'" . markdown-mode))

;; Set after the library loads, with `setopt': several of these options have a
;; setter that must run (the heading sizes rebuild the faces).
(with-eval-after-load 'markdown-mode
  (setopt markdown-command "pandoc -f gfm -t html5 --standalone --embed-resources --highlight-style=pygments"
        markdown-fontify-code-blocks-natively t
        markdown-enable-math t
        markdown-enable-wiki-links nil
        markdown-asymmetric-header t
        markdown-italic-underscore t
        markdown-list-indent-width 2
        markdown-indent-on-enter 'indent-and-new-item
        markdown-gfm-uppercase-checkbox nil
        markdown-header-scaling t
        markdown-header-scaling-values '(1.7 1.45 1.25 1.1 1.0 1.0)
        markdown-max-image-size '(900 . 700)
        markdown-use-pandoc-style-yaml-metadata t
        markdown-live-preview-delete-export 'delete-on-export
        markdown-gfm-additional-languages
        '("sql" "verilog" "systemverilog" "csharp" "c" "cpp" "nix" "bash" "shell")
        markdown-spaces-after-code-fence 0
        markdown-code-lang-modes
        '(("c" . c-ts-mode) ("cpp" . c++-ts-mode) ("csharp" . csharp-ts-mode)
          ("cs" . csharp-ts-mode) ("sql" . sql-mode) ("verilog" . verilog-mode)
          ("systemverilog" . verilog-mode) ("sv" . verilog-mode) ("nix" . nix-ts-mode)
          ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode) ("elisp" . emacs-lisp-mode)
          ("emacs-lisp" . emacs-lisp-mode) ("python" . python-ts-mode)
          ("json" . json-ts-mode) ("yaml" . yaml-ts-mode) ("toml" . toml-ts-mode)
          ("rust" . rust-ts-mode) ("js" . js-ts-mode) ("ts" . typescript-ts-mode)
          ("html" . html-mode) ("css" . css-ts-mode) ("diff" . diff-mode))))

;; Word count in the modeline, for prose only.
(setq doom-modeline-enable-word-count t
      doom-modeline-continuous-word-count-modes '(markdown-mode gfm-mode))

;;;; Hide the markup, except where you are typing

(defvar-local kitty--md-reveal-overlay nil)
(defvar-local kitty--md-reveal-line nil)

(defun kitty--md-reveal-update ()
  "Show the hidden markup on the current line only."
  (when (bound-and-true-p markdown-hide-markup)
    (let ((beg (line-beginning-position))
          (end (min (point-max) (1+ (line-end-position)))))
      (unless (and kitty--md-reveal-line (= kitty--md-reveal-line beg)
                   (overlayp kitty--md-reveal-overlay)
                   (= (overlay-end kitty--md-reveal-overlay) end))
        (if (overlayp kitty--md-reveal-overlay)
            (move-overlay kitty--md-reveal-overlay beg end)
          (setq kitty--md-reveal-overlay (make-overlay beg end nil nil t))
          ;; A non-nil `invisible' that is not in `buffer-invisibility-spec'
          ;; means "visible", and an overlay beats the text property that
          ;; markdown-mode uses to hide the markup.
          (overlay-put kitty--md-reveal-overlay 'invisible 'kitty-md-reveal))
        (setq kitty--md-reveal-line beg)))))

(define-minor-mode kitty-markdown-reveal-mode
  "Hide markdown markup everywhere but on the line with the cursor."
  :lighter nil
  (if kitty-markdown-reveal-mode
      (progn
        (markdown-toggle-markup-hiding 1)
        (add-hook 'post-command-hook #'kitty--md-reveal-update nil t)
        (kitty--md-reveal-update))
    (remove-hook 'post-command-hook #'kitty--md-reveal-update t)
    (when (overlayp kitty--md-reveal-overlay)
      (delete-overlay kitty--md-reveal-overlay))
    (setq kitty--md-reveal-overlay nil kitty--md-reveal-line nil)
    (markdown-toggle-markup-hiding -1)))

(defun kitty-markdown-toggle-markup ()
  "Toggle hiding of markdown markup."
  (interactive)
  (kitty-markdown-reveal-mode 'toggle))

;; markdown-mode hides emphasis, code, links and URLs, but leaves the # of a
;; heading showing.  With scaled headings the level is visible without it.
(defconst kitty--md-heading-hash-keyword
  '("^\\(#\\{1,6\\}[ \t]+\\)"
    (1 (progn (add-text-properties (match-beginning 1) (match-end 1)
                                   '(invisible markdown-markup rear-nonsticky t))
              nil))))

(defun kitty--markdown-hide-heading-hashes ()
  "Treat the # marks of headings as hideable markup in this buffer."
  (font-lock-add-keywords nil (list kitty--md-heading-hash-keyword) 'append)
  (setq-local font-lock-extra-managed-props
              (cons 'invisible (bound-and-true-p font-lock-extra-managed-props)))
  (font-lock-flush))

;;;; Setting up a markdown buffer

(defun kitty--markdown-setup ()
  (visual-line-mode 1)
  (setq-local line-spacing 0.25
              fill-column 80
              word-wrap t
              require-final-newline t
              ;; backticks pair like brackets
              electric-pair-pairs (append '((?` . ?`)) electric-pair-pairs)
              electric-pair-text-pairs (append '((?` . ?`)) electric-pair-text-pairs))
  (when (fboundp 'olivetti-mode)
    (setq-local olivetti-body-width 88)
    (olivetti-mode 1))
  (when (display-graphic-p)
    (when (fboundp 'mixed-pitch-mode)
      (setq-local mixed-pitch-fixed-pitch-faces
                  (append '(markdown-code-face markdown-inline-code-face markdown-pre-face
                            markdown-table-face markdown-language-keyword-face
                            markdown-markup-face markdown-metadata-key-face
                            markdown-metadata-value-face markdown-math-face
                            markdown-html-tag-name-face markdown-html-attr-name-face
                            markdown-html-attr-value-face markdown-html-entity-face
                            markdown-footnote-marker-face markdown-list-face
                            markdown-gfm-checkbox-face)
                          (bound-and-true-p mixed-pitch-fixed-pitch-faces)))
      (mixed-pitch-mode 1))
    (when (fboundp 'valign-mode) (valign-mode 1)))
  (kitty--markdown-hide-heading-hashes)
  (kitty-markdown-reveal-mode 1)
  (when (display-graphic-p) (markdown-display-inline-images))
  (cond ((and (fboundp 'jinx-mode) (not (kitty-windows-p))) (jinx-mode 1))
        ((executable-find (or (bound-and-true-p ispell-program-name) "aspell")) (flyspell-mode 1)))
  (when (executable-find "marksman") (eglot-ensure)))

(kitty-add-hook 'markdown-mode-hook #'kitty--markdown-setup)
(kitty-add-hook 'gfm-mode-hook #'kitty--markdown-setup)

;; The language server comes from kitty-prog (eglot); this tells it about us.
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((markdown-mode gfm-mode) . ("marksman" "server"))))

;;;; RET and o: lists continue, as in my-nvim (config/markdown_lists.lua)

(declare-function evil-normal-state-p "evil-states")
(declare-function evil-ret "evil-commands")
(declare-function evil-insert-state "evil-states")

(defun kitty-markdown-ret ()
  "Typing: a new line that continues the list.  In the normal state: Vim's RET,
except on a link, which it follows."
  (interactive)
  (if (and (fboundp 'evil-normal-state-p) (evil-normal-state-p))
      (if (or (markdown-link-at-pos (point)) (markdown-wiki-link-p) (thing-at-point-url-at-point))
          (markdown-follow-thing-at-point nil)
        (call-interactively #'evil-ret))
    (markdown-enter-key)))

(defun kitty-markdown-open-below ()
  "Open a line below, continuing the list item it is in (my-nvim's o in markdown)."
  (interactive)
  ;; Exactly what RET does at the end of the line: it continues lists.
  (end-of-line)
  (evil-insert-state)
  (markdown-enter-key))

(defun kitty--markdown-task-item-p ()
  "Non-nil when point is on a GFM task list item."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[ \t]*\\(?:[-*+]\\|[0-9]+[.)]\\)[ \t]+\\[[ xX]\\]")))

(with-eval-after-load 'markdown-mode
  (define-key markdown-mode-map (kbd "RET") #'kitty-markdown-ret)
  (with-eval-after-load 'evil
    (evil-define-key* 'normal markdown-mode-map
      (kbd "o") #'kitty-markdown-open-below
      (kbd "RET") #'kitty-markdown-ret))
  ;; subtree and list movement on the keys Emacs users expect
  (define-key markdown-mode-map (kbd "M-<up>") #'markdown-move-up)
  (define-key markdown-mode-map (kbd "M-<down>") #'markdown-move-down)
  (define-key markdown-mode-map (kbd "M-<left>") #'markdown-promote)
  (define-key markdown-mode-map (kbd "M-<right>") #'markdown-demote)
  (define-key markdown-mode-map (kbd "<backtab>") #'markdown-shifttab))

;;;; Images from the clipboard

(defun kitty-markdown--save-clipboard-image (file)
  "Write the image on the clipboard to FILE as PNG; return the exit status (0 = done)."
  (if (kitty-windows-p)
      (call-process "powershell" nil nil nil "-NoProfile" "-Command"
                    (format (concat "Add-Type -AssemblyName System.Windows.Forms;"
                                    "Add-Type -AssemblyName System.Drawing;"
                                    "$i=[System.Windows.Forms.Clipboard]::GetImage();"
                                    "if($i -eq $null){exit 1};"
                                    "$i.Save('%s',[System.Drawing.Imaging.ImageFormat]::Png)")
                            (replace-regexp-in-string "'" "''" (convert-standard-filename file))))
    (call-process-shell-command
     (format "wl-paste --type image/png > %s" (shell-quote-argument file)))))

(defun kitty-markdown-paste-image ()
  "Save the image on the clipboard next to the document and link it."
  (interactive)
  (unless buffer-file-name (user-error "Save the buffer first"))
  (let* ((dir (expand-file-name "assets" (file-name-directory buffer-file-name)))
         (name (format-time-string "paste-%Y%m%d-%H%M%S.png"))
         (file (expand-file-name name dir)))
    (make-directory dir t)
    (if (zerop (kitty-markdown--save-clipboard-image file))
        (progn (insert (format "![](assets/%s)" name))
               (markdown-display-inline-images))
      (ignore-errors (delete-file file))
      (user-error "No image on the clipboard"))))

;;;; Preview and export

(defun kitty-markdown-preview ()
  "Live preview next to the buffer (re-rendered as you edit)."
  (interactive)
  (markdown-live-preview-mode 'toggle))

(defun kitty-markdown-export (format)
  "Convert the file with pandoc to FORMAT (html, docx, pdf, org, rst, odt)."
  (interactive (list (completing-read "Export to: " '("html" "docx" "pdf" "org" "rst" "odt") nil t)))
  (unless buffer-file-name (user-error "Save the buffer first"))
  (let ((out (concat (file-name-sans-extension buffer-file-name) "." format)))
    (save-buffer)
    (if (zerop (call-process "pandoc" nil "*pandoc*" nil "-f" "gfm" buffer-file-name "-o" out))
        (message "Wrote %s" out)
      (display-buffer "*pandoc*")
      (user-error "pandoc failed"))))

;;;; SPC m in markdown buffers

(defvar kitty-markdown-insert-map
  (kitty-keymap
   "l" '("link" . markdown-insert-link)
   "i" '("image" . markdown-insert-image)
   "p" '("paste image" . kitty-markdown-paste-image)
   "c" '("code block" . markdown-insert-gfm-code-block)
   "t" '("table" . markdown-insert-table)
   "f" '("footnote" . markdown-insert-footnote)
   "h" '("heading" . markdown-insert-header-dwim)
   "-" '("rule" . markdown-insert-hr)
   "q" '("quote" . markdown-insert-blockquote)
   "L" '("list item" . markdown-insert-list-item)
   "T" '("table of contents" . markdown-toc-generate-or-refresh-toc)))

(defvar kitty-markdown-format-map
  (kitty-keymap
   "b" '("bold" . markdown-insert-bold)
   "i" '("italic" . markdown-insert-italic)
   "c" '("code" . markdown-insert-code)
   "s" '("strike" . markdown-insert-strike-through)
   "k" '("kbd" . markdown-insert-kbd)
   "q" '("quote" . markdown-insert-blockquote)
   "p" '("pre block" . markdown-insert-pre)))

(kitty-local-leader 'markdown-mode
  "i" (cons "insert" kitty-markdown-insert-map)
  "f" (cons "format" kitty-markdown-format-map)
  "x" '("checkbox" . markdown-toggle-gfm-checkbox)
  "e" '("edit code block" . markdown-edit-code-block)
  "p" '("live preview" . kitty-markdown-preview)
  "o" '("open in browser" . markdown-export-and-preview)
  "E" '("export (pandoc)" . kitty-markdown-export)
  "t" '("table align" . markdown-table-align)
  "T" '("table of contents" . markdown-toc-generate-or-refresh-toc)
  "l" '("follow link" . markdown-follow-thing-at-point)
  "v" '("inline images" . markdown-toggle-inline-images)
  "m" '("hide markup" . kitty-markdown-toggle-markup)
  "n" '("next heading" . markdown-outline-next)
  "N" '("previous heading" . markdown-outline-previous)
  "u" '("up heading" . markdown-up-heading)
  "r" '("renumber list" . markdown-cleanup-list-numbers)
  "j" '("jump (headings)" . consult-outline)
  "c" '("complete buffer" . markdown-complete-buffer))

;; my-nvim's <leader>ce: edit the code block under the cursor in its own buffer.
(kitty-mode-leader 'markdown-mode "c e" '("edit code block" . markdown-edit-code-block))

(provide 'kitty-markdown)
;;; kitty-markdown.el ends here
