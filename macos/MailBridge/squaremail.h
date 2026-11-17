#ifndef SQUAREMAIL_H
#define SQUAREMAIL_H
// The caller owns each response and must release it exactly once.
char *squaremail_call(const char *request);
void squaremail_free(char *response);

typedef struct SquareMailToken SquareMailToken;
SquareMailToken *squaremail_token_new(void);
void squaremail_token_cancel(const SquareMailToken *token);
void squaremail_token_free(SquareMailToken *token);
char *squaremail_call_cancelable(const char *request, const SquareMailToken *token);

#endif
