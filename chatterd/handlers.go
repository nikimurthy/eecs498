package main

import (
    "log"
    "net/http"
    "net/http/httputil"
    "net/url"

    "github.com/labstack/echo/v4"
)

func logOk(c echo.Context) {
	log.Println("[Echo] |", http.StatusOK, `|`, c.RealIP(), `|`, c.Request().Method, c.Request().RequestURI)
}

func top(c echo.Context) error {
	logOk(c)
	return c.JSON(http.StatusOK, "EECS Reactive chatterd")
}

var OLLAMA_BASE_URL, _ = url.Parse("http://localhost:11434/api")
var proxy = httputil.NewSingleHostReverseProxy(OLLAMA_BASE_URL)

func llmprompt(c echo.Context) error {
    req := c.Request()
    req.Host = OLLAMA_BASE_URL.Host
    req.URL.Path = "/generate"

    proxy.ServeHTTP(c.Response(), req)
    logOk(c)
    return nil
}

