#ifndef SQUAREMAIL_H
#define SQUAREMAIL_H
// The caller owns each response and must release it exactly once.
char *squaremail_call(const char *request);
void squaremail_free(char *response);
#endif
