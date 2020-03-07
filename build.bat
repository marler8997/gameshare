set DCOMPILER=dmd
set MORED=..\mored

@if not exist %MORED% (
    echo ERROR: repo %MORED% does not exist, run: git clone https://github.com/marler8997/mored %MORED%
    exit /b 1
)

call %DCOMPILER% -I=..\mored -i server.d
@if %errorlevel% neq 0 exit /b %errorlevel%

call %DCOMPILER% -I=..\mored -i client.d
@if %errorlevel% neq 0 exit /b %errorlevel%

@echo Success
