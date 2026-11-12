;;; kitty-completion.el --- vertico, orderless, consult, embark, corfu  -*- lexical-binding: t; -*-

;;; Commentary:

;; The minibuffer: vertico lists, orderless matches (space-separated words in
;; any order, ! to exclude), marginalia annotates, consult searches and
;; previews, embark acts on whatever is selected.  In buffers: corfu pops up
;; candidates as you type, cape adds files and words, yasnippet expands.

;;; Code:

(require 'kitty-lib)

;;;; Matching

(setq completion-styles '(orderless basic)
      completion-category-defaults nil
      completion-category-overrides '((file (styles basic partial-completion))
                                      (eglot (styles orderless))
                                      (eglot-capf (styles orderless)))
      completion-ignore-case t
      read-file-name-completion-ignore-case t
      read-buffer-completion-ignore-case t
      completions-detailed t
      completion-cycle-threshold nil
      orderless-matching-styles '(orderless-literal orderless-regexp)
      orderless-style-dispatchers '(orderless-affix-dispatch))

;;;; vertico, marginalia, icons

(setq vertico-cycle t
      vertico-count 14
      vertico-resize nil
      marginalia-max-relative-age 0)

(defun kitty--completion-ui ()
  (when (require 'vertico nil t)
    (vertico-mode 1)
    (when (require 'vertico-directory nil t)
      (define-key vertico-map (kbd "RET") #'vertico-directory-enter)
      (define-key vertico-map (kbd "DEL") #'vertico-directory-delete-char)
      (define-key vertico-map (kbd "M-DEL") #'vertico-directory-delete-word)
      (add-hook 'rfn-eshadow-update-overlay-hook #'vertico-directory-tidy))
    (when (require 'vertico-repeat nil t)
      (add-hook 'minibuffer-setup-hook #'vertico-repeat-save)))
  (when (require 'marginalia nil t) (marginalia-mode 1))
  (when (require 'nerd-icons-completion nil t) (nerd-icons-completion-mode 1)))
(add-hook 'emacs-startup-hook #'kitty--completion-ui)

;;;; consult

(setq consult-narrow-key "<"
      consult-preview-key "M-."
      consult-async-min-input 2
      consult-async-refresh-delay 0.15
      consult-async-input-throttle 0.2
      consult-async-input-debounce 0.1
      consult-ripgrep-args "rg --null --line-buffered --color=never --max-columns=1000 --path-separator / --smart-case --no-heading --with-filename --line-number --search-zip --hidden --glob=!.git/")

(setq xref-show-xrefs-function #'consult-xref
      xref-show-definitions-function #'consult-xref)

(with-eval-after-load 'consult
  ;; Previews that would be slow or noisy only appear on demand.  `consult-customize'
  ;; is a macro of consult, which is not loaded when this file is compiled, so
  ;; it is expanded when it runs rather than compiled as a function call.
  (eval '(consult-customize
          consult-ripgrep consult-git-grep consult-grep consult-recent-file
          consult-bookmark consult-xref
          :preview-key '(:debounce 0.4 any))
        t))

(global-set-key [remap switch-to-buffer] #'consult-buffer)
(global-set-key [remap switch-to-buffer-other-window] #'consult-buffer-other-window)
(global-set-key [remap project-switch-to-buffer] #'consult-project-buffer)
(global-set-key [remap yank-pop] #'consult-yank-pop)
(global-set-key [remap goto-line] #'consult-goto-line)
(global-set-key [remap imenu] #'consult-imenu)
(global-set-key [remap bookmark-jump] #'consult-bookmark)

;;;; embark

(setq embark-prompter #'embark-completing-read-prompter
      prefix-help-command #'embark-prefix-help-command
      embark-indicators '(embark-minimal-indicator embark-highlight-indicator
                          embark-isearch-highlight-indicator))
(global-set-key (kbd "C-.") #'embark-act)
(global-set-key (kbd "C-;") #'embark-dwim)
(with-eval-after-load 'embark (require 'embark-consult nil t))
(with-eval-after-load 'wgrep (setq wgrep-auto-save-buffer t))

;;;; corfu: candidates while typing

(setq corfu-auto t
      corfu-auto-delay 0.12
      corfu-auto-prefix 2
      corfu-cycle t
      corfu-preselect 'prompt               ; RET inserts a newline unless you chose something
      corfu-quit-no-match 'separator
      corfu-count 12
      corfu-max-width 90
      corfu-popupinfo-delay '(0.4 . 0.2)
      corfu-on-exact-match nil
      text-mode-ispell-word-completion nil)

(defun kitty--corfu ()
  (when (require 'corfu nil t)
    (global-corfu-mode 1)
    (when (require 'corfu-popupinfo nil t) (corfu-popupinfo-mode 1))
    (when (require 'corfu-history nil t) (corfu-history-mode 1))
    (define-key corfu-map (kbd "TAB") #'corfu-next)
    (define-key corfu-map (kbd "<tab>") #'corfu-next)
    (define-key corfu-map (kbd "S-TAB") #'corfu-previous)
    (define-key corfu-map (kbd "<backtab>") #'corfu-previous)
    ;; Vim's popup keys, as in my-nvim: C-n / C-p pick, C-y accepts, C-e closes
    ;; (RET only accepts an item you picked: `corfu-preselect' is 'prompt).
    (define-key corfu-map (kbd "C-n") #'corfu-next)
    (define-key corfu-map (kbd "C-p") #'corfu-previous)
    (define-key corfu-map (kbd "C-y") #'corfu-insert)
    (define-key corfu-map (kbd "C-e") #'corfu-quit)
    (define-key corfu-map (kbd "M-SPC") #'corfu-insert-separator))
  (when (require 'nerd-icons-corfu nil t)
    (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter)))
(add-hook 'emacs-startup-hook #'kitty--corfu)

;; Fallback sources everywhere: file names, then words from open buffers.
(add-hook 'completion-at-point-functions #'cape-file)
(add-hook 'completion-at-point-functions #'cape-dabbrev t)

;;;; Snippets

(setq yas-snippet-dirs (list (expand-file-name "snippets" kitty-config-dir))
      yas-verbosity 0)
(dolist (hook '(prog-mode-hook text-mode-hook))
  (kitty-add-hook hook #'yas-minor-mode-on))

;;;; Undo

(with-eval-after-load 'vundo
  (setq vundo-glyph-alist vundo-unicode-symbols))
(define-key mode-specific-map (kbd "U") '("undo tree" . vundo))

(provide 'kitty-completion)
;;; kitty-completion.el ends here
