package main

import (
	"log"
  
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
)

type Route struct {
    HTTPMethod string
    URLPath    string
    URLHandler echo.HandlerFunc
}

var routes = []Route {
		// {"GET", "/", top},	
		{"POST", "/llmprompt/", llmprompt},
}

func main() {
	server := echo.New()
	server.HideBanner = true
	for _, route := range routes {
		server.Match([]string{route.HTTPMethod}, route.URLPath, route.URLHandler)
	}
	server.Pre(middleware.AddTrailingSlash())

	log.Fatal(server.StartTLS(":443",
		"/home/ubuntu/reactive/chatterd.crt",
		"/home/ubuntu/reactive/chatterd.key"))
}

