;;; kitty-lean-widgets.el --- Lean's widgets in the infoview, as text  -*- lexical-binding: t; -*-

;;; Commentary:

;; VS Code's infoview runs a widget's JavaScript (React) to draw it.  Emacs
;; has no JavaScript, so kittymax draws the widgets people meet, from the
;; same data (the widget's props), as lean.nvim does:
;;
;;   - `Try this' in a message (Lean.Meta.Hint.textInsertionWidget, and the
;;     older tryThisDiffWidget / TryThis.tryThisWidget): [apply] buttons that
;;     put the suggestion in the file;
;;   - an error's code and its explanation (Lean.errorDescriptionWidget);
;;   - ProofWidgets' HTML (HtmlDisplay, HtmlDisplayPanel, #html): headings,
;;     paragraphs, lists, bold / italic / code, colours, links, tables,
;;     <details> as folds, MakeEditLink buttons, terms you can hover (K) and
;;     follow (gd), and <svg> drawn as an image in a graphical Emacs.
;;
;; A widget it does not know shows what Lean gives instead (a message's
;; `alt' text), or its name and that it needs VS Code.  A button that edits
;; the file does so only if the file is still the text the infoview shows:
;; otherwise the infoview is asked again (test/kitty_lean_folds.tla).

;;; Code:

(require 'kitty-lean)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'xml)

(declare-function browse-url "browse-url")

(defface kitty-lean-widget-button '((t :inherit link))
  "A widget's button: [apply], a link." :group (quote kitty-lean))
(defface kitty-lean-widget-inserted '((t :inherit diff-refine-added))
  "Text a suggestion adds." :group (quote kitty-lean))
(defface kitty-lean-widget-deleted '((t :inherit diff-refine-removed :strike-through t))
  "Text a suggestion takes away." :group (quote kitty-lean))
(defface kitty-lean-widget-code '((t :inherit (fixed-pitch font-lock-constant-face)))
  "<code> in a widget's HTML." :group (quote kitty-lean))
(defface kitty-lean-widget-heading '((t :inherit kitty-lean-infoview-heading))
  "<h1> ... <h6> in a widget's HTML." :group (quote kitty-lean))

(defcustom kitty-lean-widgets-images t
  "Draw a widget's <svg> as an image (in a graphical Emacs with SVG support)."
  :type 'boolean
  :group 'kitty-lean)

;;;; Buttons and edits

(defun kitty-lean-widgets-press (event)
  "Press the widget button clicked on."
  (interactive "e")
  (mouse-set-point event)
  (when-let* ((action (get-text-property (point) 'kitty-lean-action)))
    (funcall action)))

(defvar-keymap kitty-lean-widgets--button-map
  "<mouse-1>" #'kitty-lean-widgets-press
  "<mouse-2>" #'kitty-lean-widgets-press)

(defun kitty-lean-widgets--button (beg action &optional help)
  "Make the text from BEG to point a button that runs ACTION (RET, a click)."
  (add-text-properties beg (point)
                       (list 'kitty-lean-action action
                             'mouse-face 'highlight
                             'keymap kitty-lean-widgets--button-map
                             'help-echo (or help "RET or click")))
  (add-face-text-property beg (point) 'kitty-lean-widget-button))

(defun kitty-lean-widgets--edit-buffer (uri)
  "The buffer an edit for URI (nil: the infoview's file) goes to, if it is safe to.
Safe: it is the text the infoview was made from.  If not, the infoview is
asked again and the button does nothing: Lean's ranges are for that text."
  (let ((buffer (if uri (kitty-lean--buffer-for-uri uri) kitty-lean--rendered)))
    (unless (buffer-live-p buffer)
      (user-error "Lean: that file is not open"))
    (unless (and (eq buffer kitty-lean--rendered)
                 (eql (buffer-chars-modified-tick buffer) kitty-lean--rendered-tick))
      (when (buffer-live-p kitty-lean--rendered)
        (kitty-lean-infoview-refresh kitty-lean--rendered t))
      (user-error "Lean: the file changed since the infoview showed this; it is updated now, try again"))
    (with-current-buffer buffer (barf-if-buffer-read-only))
    buffer))

(defun kitty-lean-widgets--apply (buffer edits &optional selection)
  "Apply EDITS (LSP TextEdits) to BUFFER, then go there: to SELECTION's start
\(an LSP range), or after the last edit."
  (let (last)
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (undo-boundary)
        ;; Every range is in the text before any edit (LSP): all are found
        ;; first, as markers that move past what is put in at them, then
        ;; the edits go in their order (two inserts at one place: in order)
        (let ((spans (mapcar (lambda (e)
                               (let ((range (plist-get e :range)))
                                 (list (copy-marker (kitty-lean--lsp-point buffer (plist-get range :start)) t)
                                       (copy-marker (kitty-lean--lsp-point buffer (plist-get range :end)) t)
                                       (plist-get e :newText))))
                             (append edits nil))))
          (pcase-dolist (`(,beg ,end ,text) spans)
            (save-excursion
              (goto-char beg)
              (delete-region beg end)
              (insert text)
              (setq last (point-marker))))
          (pcase-dolist (`(,beg ,end ,_) spans) (set-marker beg nil) (set-marker end nil)))
        (when selection
          (setq last (copy-marker (kitty-lean--lsp-point buffer (plist-get selection :start)))))))
    (let ((w (or (get-buffer-window buffer) (display-buffer buffer))))
      (select-window w)
      (when last (goto-char last)))
    (message "Lean: applied")))

(defun kitty-lean-widgets--suggestion-action (range suggestion)
  (lambda ()
    (let ((buffer (kitty-lean-widgets--edit-buffer nil)))
      (kitty-lean-widgets--apply buffer (list (list :range range :newText suggestion))))))

;;;; Lean's own widgets

(defun kitty-lean-widgets--text-insertion (props)
  "Lean.Meta.Hint.textInsertionWidget: Try this's [apply] (Lean ≥ 4.25)."
  (let* ((accept (plist-get props :acceptSuggestionProps))
         (label (if (equal (plist-get accept :kind) "text")
                    (or (plist-get accept :linkText) "[apply]")
                  ;; a codicon: VS Code's icon font; a word for it here
                  (format "[%s]" (pcase (plist-get accept :codiconName)
                                   ((or "check" "pass" "lightbulb") "apply")
                                   (n (or n "apply"))))))
         (beg (point)))
    (insert label)
    (kitty-lean-widgets--button beg (kitty-lean-widgets--suggestion-action
                                     (plist-get props :range) (plist-get props :suggestion))
                                (format "%s: %s" (or (plist-get accept :hoverText) "Apply")
                                        (plist-get props :suggestion)))))

(defun kitty-lean-widgets--try-this-diff (props)
  "Lean.Meta.Hint.tryThisDiffWidget (Lean 4.24): the suggestion as a diff, a button."
  (let ((beg (point)))
    (seq-doseq (part (plist-get props :diff))
      (let ((b (point)))
        (insert (plist-get part :text))
        (pcase (plist-get part :type)
          ("insertion" (add-face-text-property b (point) 'kitty-lean-widget-inserted))
          ("deletion" (add-face-text-property b (point) 'kitty-lean-widget-deleted)))))
    (when (= beg (point)) (insert (plist-get props :suggestion)))
    (kitty-lean-widgets--button beg (kitty-lean-widgets--suggestion-action
                                     (plist-get props :range) (plist-get props :suggestion))
                                "Apply this suggestion")))

(defun kitty-lean-widgets--try-this (props)
  "Lean.Meta.Tactic.TryThis.tryThisWidget (Lean < 4.23): a list of suggestions."
  (insert (or (plist-get props :header) "Try this:"))
  (seq-doseq (s (plist-get props :suggestions))
    (let* ((text (if (stringp s) s (plist-get s :suggestion)))
           (text (if (stringp text) text (format "%s" text))))
      (insert "\n  ")
      (when-let* ((pre (and (consp s) (plist-get s :preInfo)))) (insert pre))
      (let ((beg (point)))
        (insert text)
        (kitty-lean-widgets--button beg (kitty-lean-widgets--suggestion-action (plist-get props :range) text)
                                    "Apply this suggestion"))
      (when-let* ((post (and (consp s) (plist-get s :postInfo)))) (insert post)))))

(defun kitty-lean-widgets--error-description (props)
  "Lean.errorDescriptionWidget: the error's code, a link to what it means."
  (insert "\nError code: " (or (plist-get props :code) "?") "  ")
  (when-let* ((url (plist-get props :explanationUrl)))
    (let ((beg (point)))
      (insert "View explanation")
      (kitty-lean-widgets--button beg (lambda () (browse-url url)) url))))

(defun kitty-lean-widgets-insert (wi embedded)
  "Insert the widget instance WI (id, props) at point, as text.
EMBEDDED: it is inside a message, which has its own text for it: nil is
returned for a widget this does not know, and the message's text is used."
  (let ((id (plist-get wi :id))
        (props (plist-get wi :props))
        (beg (point)))
    (pcase id
      ("Lean.Meta.Hint.textInsertionWidget" (kitty-lean-widgets--text-insertion props) t)
      ("Lean.Meta.Hint.tryThisDiffWidget" (kitty-lean-widgets--try-this-diff props) t)
      ("Lean.Meta.Tactic.TryThis.tryThisWidget" (kitty-lean-widgets--try-this props) t)
      ("Lean.errorDescriptionWidget" (kitty-lean-widgets--error-description props) t)
      ((or "ProofWidgets.HtmlDisplay" "ProofWidgets.HtmlDisplayPanel")
       (kitty-lean-widgets--html (plist-get props :html))
       (kitty-lean-widgets--own-faces beg (point))
       t)
      (_
       (unless embedded
         (insert (propertize (or (plist-get wi :name) id) 'face 'kitty-lean-infoview-case)
                 (propertize "  (drawn by JavaScript: open the file in VS Code to see it)" 'face 'shadow))
         t)))))

(defun kitty-lean-widgets--own-faces (beg end)
  "The infoview's own faces (`kitty-lean-face', diffs) between BEG and END."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'kitty-lean-face nil end)))
        (when-let* ((face (get-text-property pos 'kitty-lean-face)))
          (add-face-text-property pos next face))
        (setq pos next)))))

;;;; ProofWidgets' HTML

;; Html is {element: [tag, [[attr, value]...], children]}, {text: s}, or
;; {component: [hash, export, props, children]} (a React component).

(defvar kitty-lean-widgets--pre nil "Inside <pre>: whitespace as it is.")
(defvar kitty-lean-widgets--list nil "The lists around: (ul) or (ol . N) each, innermost first.")

(defun kitty-lean-widgets--attrs (raw)
  "RAW ([[name value] ...]) as an alist."
  (seq-map (lambda (a) (cons (if (stringp (seq-elt a 0)) (seq-elt a 0) (format "%s" (seq-elt a 0)))
                             (seq-elt a 1)))
           raw))

(defun kitty-lean-widgets--style (style)
  "STYLE (a CSS string or an object) as an alist of (property . value) strings."
  (cond
   ((stringp style)
    (delq nil (mapcar (lambda (decl)
                        (when (string-match "\\`\\s-*\\([-a-zA-Z]+\\)\\s-*:\\s-*\\(.*?\\)\\s-*\\'" decl)
                          (cons (downcase (match-string 1 decl)) (match-string 2 decl))))
                      (split-string style ";" t))))
   ((consp style)
    (let (out)
      (while style
        (let ((k (substring (symbol-name (car style)) 1)))
          ;; fontWeight -> font-weight
          (push (cons (downcase (let ((case-fold-search nil))
                                  (replace-regexp-in-string "\\([A-Z]\\)" "-\\1" k t)))
                      (format "%s" (cadr style)))
                out))
        (setq style (cddr style)))
      (nreverse out)))))

(defun kitty-lean-widgets--css-face (css)
  "A face (plist) for the CSS alist, or nil."
  (let (face)
    (when-let* ((c (cdr (assoc "color" css)))) (when (color-defined-p c) (setq face (plist-put face :foreground c))))
    (when-let* ((c (or (cdr (assoc "background-color" css)) (cdr (assoc "background" css)))))
      (when (color-defined-p c) (setq face (plist-put face :background c))))
    (when (member (cdr (assoc "font-weight" css)) '("bold" "bolder" "600" "700" "800" "900"))
      (setq face (plist-put face :weight 'bold)))
    (when (equal (cdr (assoc "font-style" css)) "italic") (setq face (plist-put face :slant 'italic)))
    (when-let* ((d (cdr (assoc "text-decoration" css))))
      (when (string-match-p "underline" d) (setq face (plist-put face :underline t)))
      (when (string-match-p "line-through" d) (setq face (plist-put face :strike-through t))))
    face))

(defun kitty-lean-widgets--hidden-p (css)
  (or (equal (cdr (assoc "display" css)) "none")
      (equal (cdr (assoc "visibility" css)) "hidden")))

(defun kitty-lean-widgets--bol ()
  "Start a block: on a line of its own."
  (unless (or (bobp) (bolp)) (insert "\n")))

(defun kitty-lean-widgets--html (html)
  "Insert ProofWidgets' HTML."
  (cond
   ((null html))
   ((plist-member html :text)
    (let ((text (plist-get html :text)))
      (insert (if kitty-lean-widgets--pre text
                (let ((s (replace-regexp-in-string "[ \t\n\r]+" " " text)))
                  (if (bolp) (string-trim-left s) s))))))
   ((plist-member html :element)
    (let ((el (plist-get html :element)))
      (kitty-lean-widgets--element (seq-elt el 0) (kitty-lean-widgets--attrs (seq-elt el 1)) (seq-elt el 2))))
   ((plist-member html :component)
    (let* ((c (plist-get html :component))
           (props (seq-elt c 2))
           (children (seq-elt c 3)))
      (kitty-lean-widgets--component props children)))))

(defun kitty-lean-widgets--children (children)
  (seq-do #'kitty-lean-widgets--html children))

(defun kitty-lean-widgets--component (props children)
  "A React component of ProofWidgets: those whose props say what they are."
  (cond
   ;; <InteractiveCode fmt={...}/>: a term, with K and gd
   ((plist-get props :fmt)
    (let ((beg (point)))
      (kitty-lean--insert-tagged (plist-get props :fmt))
      (kitty-lean--fontify-region beg (point)))
    (kitty-lean-widgets--children children))
   ;; <MakeEditLink edit={...}>children</MakeEditLink>
   ((plist-get props :edit)
    (let* ((edit (plist-get props :edit))
           (uri (plist-get (plist-get edit :textDocument) :uri))
           (selection (plist-get props :newSelection))
           (beg (point)))
      (kitty-lean-widgets--children children)
      (when (= beg (point)) (insert (or (plist-get props :title) "Apply edit")))
      (kitty-lean-widgets--button
       beg (lambda ()
             (kitty-lean-widgets--apply (kitty-lean-widgets--edit-buffer uri) (plist-get edit :edits) selection))
       (or (plist-get props :title) "Apply this edit"))))
   ((stringp (plist-get props :contents))
    (insert (plist-get props :contents))
    (kitty-lean-widgets--children children))
   (t (kitty-lean-widgets--children children))))

(defconst kitty-lean-widgets--blocks
  '("div" "p" "section" "article" "header" "footer" "main" "nav" "aside" "blockquote"
    "figure" "figcaption" "form" "fieldset" "dl" "dt" "dd" "ul" "ol"))

(defun kitty-lean-widgets--element (tag attrs children)
  (let* ((css (kitty-lean-widgets--style (cdr (assoc "style" attrs))))
         (beg (point)))
    (unless (kitty-lean-widgets--hidden-p css)
      (pcase tag
        ("br" (insert "\n"))
        ("hr" (kitty-lean-widgets--bol) (insert (make-string 24 ?─) "\n"))
        ((pred (string-match-p "\\`h[1-6]\\'"))
         (kitty-lean-widgets--bol)
         (kitty-lean-widgets--children children)
         (add-face-text-property beg (point) 'kitty-lean-widget-heading)
         (insert "\n"))
        ("pre"
         (kitty-lean-widgets--bol)
         (let ((kitty-lean-widgets--pre t)) (kitty-lean-widgets--children children))
         (add-face-text-property beg (point) 'fixed-pitch)
         (kitty-lean-widgets--bol))
        ((or "ul" "ol")
         (kitty-lean-widgets--bol)
         (let ((kitty-lean-widgets--list (cons (if (equal tag "ol") (cons 'ol 0) (list 'ul))
                                                kitty-lean-widgets--list)))
           (kitty-lean-widgets--children children))
         (kitty-lean-widgets--bol))
        ("li"
         (kitty-lean-widgets--bol)
         (let ((l (car kitty-lean-widgets--list)))
           (insert (make-string (* 2 (max 0 (1- (length kitty-lean-widgets--list)))) ?\s)
                   (if (eq (car-safe l) 'ol) (format "%d. " (setcdr l (1+ (cdr l)))) "• ")))
         (kitty-lean-widgets--children children)
         (kitty-lean-widgets--bol))
        ((or "b" "strong") (kitty-lean-widgets--children children) (add-face-text-property beg (point) 'bold))
        ((or "i" "em") (kitty-lean-widgets--children children) (add-face-text-property beg (point) 'italic))
        ("u" (kitty-lean-widgets--children children) (add-face-text-property beg (point) 'underline))
        ((or "s" "del" "strike") (kitty-lean-widgets--children children)
         (add-face-text-property beg (point) '(:strike-through t)))
        ((or "code" "kbd" "samp" "tt") (kitty-lean-widgets--children children)
         (add-face-text-property beg (point) 'kitty-lean-widget-code))
        ("a"
         (kitty-lean-widgets--children children)
         (let ((href (cdr (assoc "href" attrs))))
           (when (and (stringp href) (string-match-p "\\`\\(?:https?\\|mailto\\):" href))
             (when (= beg (point)) (insert href))
             (kitty-lean-widgets--button beg (lambda () (browse-url href)) href))))
        ("img" (insert (format "[image%s]" (if-let* ((alt (cdr (assoc "alt" attrs)))) (concat ": " alt) ""))))
        ("details" (kitty-lean-widgets--details attrs children))
        ("table" (kitty-lean-widgets--table children))
        ("svg" (kitty-lean-widgets--svg attrs children))
        ((or "script" "style" "head" "template"))
        (_
         (let ((block (member tag kitty-lean-widgets--blocks)))
           (when block (kitty-lean-widgets--bol))
           (kitty-lean-widgets--children children)
           (when block (kitty-lean-widgets--bol)))))
      (when-let* ((face (kitty-lean-widgets--css-face css)))
        (add-face-text-property beg (point) face))
      (when-let* ((title (cdr (assoc "title" attrs))))
        (when (stringp title) (put-text-property beg (point) 'help-echo title))))))

(defun kitty-lean-widgets--details (attrs children)
  "<details><summary>...</summary>...</details>: a fold."
  (let* ((summary (seq-find (lambda (c) (equal (seq-elt (plist-get c :element) 0) "summary"))
                            (seq-filter (lambda (c) (plist-get c :element)) children)))
         (rest (seq-remove (lambda (c) (eq c summary)) children)))
    (kitty-lean-widgets--bol)
    (kitty-lean--fold
     (list 'details (if summary (kitty-lean-widgets--plain (seq-elt (plist-get summary :element) 2)) ""))
     (assoc "open" attrs)
     (lambda ()
       (if summary (kitty-lean-widgets--children (seq-elt (plist-get summary :element) 2))
         (insert "Details")))
     (lambda ()
       (insert "\n")
       (kitty-lean-widgets--children rest)
       (when (eq (char-before) ?\n) (delete-char -1))))
    (insert "\n")))

(defun kitty-lean-widgets--plain (children)
  (with-temp-buffer
    (cl-letf (((symbol-function 'kitty-lean--fold) (lambda (_k _d title &rest _) (funcall title))))
      (kitty-lean-widgets--children children))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun kitty-lean-widgets--rows (children)
  "The rows of a <table>'s CHILDREN, through thead / tbody / tfoot: ((header-p . cells) ...)."
  (let (rows)
    (seq-doseq (c children)
      (when-let* ((el (plist-get c :element)))
        (pcase (seq-elt el 0)
          ((and section (or "thead" "tbody" "tfoot"))
           (seq-doseq (r (seq-elt el 2))
             (when (equal (seq-elt (plist-get r :element) 0) "tr")
               (push (cons (equal section "thead") (seq-elt (plist-get r :element) 2)) rows))))
          ("tr" (push (cons nil (seq-elt el 2)) rows)))))
    (nreverse rows)))

(defun kitty-lean-widgets--cell (cell)
  "A table CELL (<td>, <th>) as a one-line string with its faces."
  (with-temp-buffer
    (cl-letf (((symbol-function 'kitty-lean--fold) (lambda (_k _d title &rest _) (funcall title))))
      (kitty-lean-widgets--children (and (plist-get cell :element) (seq-elt (plist-get cell :element) 2))))
    (when (equal (and (plist-get cell :element) (seq-elt (plist-get cell :element) 0)) "th")
      (add-face-text-property (point-min) (point-max) 'bold))
    (string-trim (replace-regexp-in-string "\n" " " (buffer-string)))))

(defun kitty-lean-widgets--table (children)
  "<table>: its rows in aligned columns, │ between them, a rule under a header."
  (let* ((rows (mapcar (lambda (r) (cons (car r) (mapcar #'kitty-lean-widgets--cell
                                                          (seq-filter (lambda (c) (plist-get c :element)) (cdr r)))))
                       (kitty-lean-widgets--rows children)))
         (ncols (apply #'max 0 (mapcar (lambda (r) (length (cdr r))) rows)))
         (widths (cl-loop for i below ncols
                          collect (apply #'max 1 (mapcar (lambda (r) (string-width (or (nth i (cdr r)) ""))) rows)))))
    (kitty-lean-widgets--bol)
    (dolist (r rows)
      (cl-loop for w in widths for i from 0
               for cell = (or (nth i (cdr r)) "")
               do (insert (if (> i 0) " │ " "") cell (make-string (- w (string-width cell)) ?\s)))
      (delete-horizontal-space)
      (insert "\n")
      (when (car r)
        (insert (mapconcat (lambda (w) (make-string w ?─)) widths "─┼─") "\n")))))

;;;; SVG

(defun kitty-lean-widgets--xml (html)
  "HTML (an <svg> tree) as XML text."
  (cond
   ((plist-member html :text) (xml-escape-string (plist-get html :text)))
   ((plist-member html :element)
    (let* ((el (plist-get html :element))
           (tag (seq-elt el 0)))
      (concat "<" tag
              (mapconcat (lambda (a)
                           (let ((v (cdr a)))
                             (format " %s=\"%s\"" (car a)
                                     (xml-escape-string
                                      (cond ((stringp v) v)
                                            ((and (consp v) (equal (car a) "style"))
                                             (mapconcat (lambda (p) (format "%s:%s" (car p) (cdr p)))
                                                        (kitty-lean-widgets--style v) ";"))
                                            (t (format "%s" v)))))))
                         (kitty-lean-widgets--attrs (seq-elt el 1)) "")
              (if (and (equal tag "svg") (not (assoc "xmlns" (kitty-lean-widgets--attrs (seq-elt el 1)))))
                  " xmlns=\"http://www.w3.org/2000/svg\"" "")
              ">" (mapconcat #'kitty-lean-widgets--xml (seq-elt el 2) "") "</" tag ">")))
   (t "")))

(defun kitty-lean-widgets--svg (attrs children)
  "<svg>: an image in a graphical Emacs, else a note that there is one."
  (let ((xml (kitty-lean-widgets--xml
              (list :element (vector "svg" (vconcat (mapcar (lambda (a) (vector (car a) (cdr a))) attrs))
                                     children)))))
    (if (and kitty-lean-widgets-images (display-graphic-p) (image-type-available-p 'svg))
        (insert-image (create-image xml 'svg t) "[SVG]")
      (insert (propertize "[an SVG drawing: a graphical Emacs shows it]" 'face 'shadow)))))

(provide 'kitty-lean-widgets)
;;; kitty-lean-widgets.el ends here
