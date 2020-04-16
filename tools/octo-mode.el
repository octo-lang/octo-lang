;;; octo-mode.el --- A simple major mode providing syntax highlighting for octo-lang.
;;; -*- coding: utf-8; lexical-binding: t; -*-
;;; Commentary:

;;; Code:

(defconst octo-highlights
  '(("where\\|type\\|int\\|case\\|of"    . font-lock-keyword-face)
    ("--.*\n"                            . font-lock-comment-face)
    ("\\([a-zA-Z]*\\)\\([a-zA-Z _]*\\)=" . (2 font-lock-variable-name-face))
    ("\\([a-zA-Z]*\\).*="                . (1 font-lock-function-name-face))))

(defun indent-line ()
  "Indent current line as octo code."
  (interactive)
  (let (begin curindent b1 e1 actindent)
    (setq begin (point))
    (if (= 1 (line-number-at-pos)) ; The first line is never indented
        (setq curindent 0)
      (progn
        (beginning-of-line)
        (setq b1 (point)) ; Get the indentation level of this line.
        (skip-chars-forward " ")
        (setq e1 (point))
        (beginning-of-line)
        (setq actindent (- e1 b1))
         (if (looking-at "\\(\n\n[a-zA-Z]*\\).*=") ; If the line is a function declaration
             (setq curindent 0)                    ; to 0.
           (progn
             (forward-line -1)
             ; Indent the line if the line before is a function declaration
             (if (and (looking-at "\\([a-zA-Z]*\\).*=") (not (looking-at "[ ]+")))
                 (progn
                   (forward-line 1)
                   (setq curindent 2))
               (let (b e)
                 (setq b (point)) ; Get the indentation level of the previous line.
                 (skip-chars-forward " ")
                 (setq e (point))
                 (if (looking-at ".*where\n\\|.*case.*of\n")
                     (progn
                       (forward-line 1)
                       (setq curindent (+ (- e b) 2)))
                   (progn
                     (forward-line 1) ; Set the indentation according to the last line
                     (setq curindent (- e b))))))))))
      (indent-line-to curindent)
      (if (/= curindent actindent)
          (goto-char (- (+ curindent begin) actindent)))
      (skip-chars-forward " ")))

(define-derived-mode octo-mode fundamental-mode "octo"
  "major mode for editing octo language code."
  (setq comment-add    "-- " ; Set up the comment style
        comment-style  "-- "
        comment-styles "-- "
        comment-start  "-- "
        comment-end    ""
        comment-auto-fill-only-comments t
        font-lock-defaults '(octo-highlights)) ; Activate syntax highlighting
  (set (make-local-variable 'indent-line-function) 'indent-line)
  (setq display-line-numbers t))

(add-to-list 'auto-mode-alist
             '("\\.oc\\'" . octo-mode)) ; Open the mode on each ".oc" file

(provide 'octo-mode)
;;; octo-mode ends here