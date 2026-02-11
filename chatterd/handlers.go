package main

import (
    "log"
    "net/http"
    "net/http/httputil"
    "net/url"
    "time"
    "github.com/labstack/echo/v4"
)

type Chatt struct {
    Name  string    `json:"name"`
    Message   string    `json:"message"`
    Id        string    `json:"id"`
    Timestamp time.Time `json:"timestamp"`
}

func logServerErr(c echo.Context, err error) error {
	log.Println("[Echo] |", http.StatusInternalServerError, `|`, c.RealIP(), `|`, c.Request().Method, c.Request().RequestURI, err.Error())
	return c.JSON(http.StatusInternalServerError, err.Error())
}

func logClientErr(c echo.Context, sc int, err error) error {
	log.Println("[Echo] |", sc, `|`, c.RealIP(), `|`, c.Request().Method, c.Request().RequestURI, err.Error())
	return c.JSON(sc, err.Error())
}

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

func getchatts(c echo.Context) error {
    var chattArr = [][]any{}
    var chatt Chatt

    rows, err := chatterDB.Query(background, `SELECT name, message, id, time FROM chatts ORDER BY time ASC`)
    if err != nil {
      if rows != nil { rows.Close() }
		  return logServerErr(c, err)
    }

    for rows.Next() {
        err = rows.Scan(&chatt.Name, &chatt.Message, &chatt.Id, &chatt.Timestamp)
        if err != nil {
          rows.Close()
          return logServerErr(c, err)
        }
        chattArr = append(chattArr, []any{chatt.Name, chatt.Message, chatt.Id, chatt.Timestamp})
    }

    logOk(c)
    return c.JSON(http.StatusOK, chattArr)
}

func postchatt(c echo.Context) error {
    var chatt Chatt

    if err := c.Bind(&chatt); err != nil {
      return logClientErr(c, http.StatusUnprocessableEntity, err)
    }

    _, err := chatterDB.Exec(background, `INSERT INTO chatts (name, message, id) VALUES ($1, $2, gen_random_uuid())`, chatt.Name, chatt.Message)
    if err != nil {
        return logClientErr(c, http.StatusBadRequest, err)
    }

    logOk(c)
	  return c.JSON(http.StatusOK, struct{}{}) // empty struct instance serialized to empty JSON: {}
}

