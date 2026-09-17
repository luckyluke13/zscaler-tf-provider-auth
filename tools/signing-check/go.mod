module zscaler-signing-check

go 1.25.8

require github.com/zscaler/zscaler-sdk-go/v3 v3.8.48

require github.com/golang-jwt/jwt/v5 v5.3.1 // indirect

replace github.com/zscaler/zscaler-sdk-go/v3 => ../../build/zscaler-sdk-go
