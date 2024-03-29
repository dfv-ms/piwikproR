#' Send the query and receive the result
#'
#' @param query list generated by \code{\link{build_query}}
#' @param token login token generated by \code{\link{get_login_token}}
#' @param use_csv logical to choose whether to fetch data via extra csv-request
#' @param fetch_by_day logical fetch data day by day
#' @param api API endpoint ("query", "sessions", "events")
#' @param caching logical Set TRUE to enable caching
#' @param caching_dir character Set directory for saving caching data, default
#' cache
#' @param convert_types logical guess type of columns and set them
#' @return result as tibble
#' @importFrom magrittr %>%
#' @importFrom magrittr extract2
#' @importFrom dplyr first
#' @importFrom dplyr bind_rows
#' @importFrom dplyr count
#' @importFrom purrr map
#' @importFrom purrr flatten_chr
#' @importFrom purrr pmap
#' @importFrom purrr map_dfr
#' @importFrom purrr pmap_dfr
#' @importFrom purrr map_lgl
#' @importFrom purrr flatten
#' @importFrom purrr set_names
#' @importFrom tibble tibble
#' @importFrom tibble as_tibble
#' @importFrom lubridate ymd
#' @export
#'

send_query <- function(query, token, use_csv = TRUE, fetch_by_day = FALSE,
                       api = "query", caching = FALSE, caching_dir = "cache",
                       convert_types = TRUE) {
  if (fetch_by_day && query$date_from != query$date_to) {
    dates <- seq.Date(
      from = ymd(query$date_from),
      to = ymd(query$date_to),
      by = "days"
    )

    if ((map_lgl(query$columns, ~ .x[[1]] == "timestamp") %>% any()) |
        api %in% c("sessions", "events")
        ) {
      # already a timestamp column in columns
    } else {
      query$columns[[length(query$columns) + 1]] <-
        list("column_id" = "timestamp")
    }

    send_query_per_date <- function(single_date) {
      query$date_from <- as.character(single_date)
      query$date_to <- as.character(single_date)
      send_query(query, token, use_csv, fetch_by_day = TRUE, api = api,
                 caching = caching, caching_dir = caching_dir,
                 convert_types = FALSE)
    }

    result_data <- pmap_dfr(list(dates), send_query_per_date)
  } else {
    result <- send_query_single(query, token, use_csv, api = api,
                                caching = caching, caching_dir = caching_dir)
    result_data <- result$data

    if ((result$meta$count > result$data %>% count() + query$offset) &&
      (result$data %>% count() + query$offset > query$max_lines)
    ) {
      next_query <- query
      next_query$offset <- next_query$offset + MAX_LINES_PER_REQUEST_ANALYTICS_API()
      next_result <- send_query(next_query, token, use_csv, api = api,
                                caching = caching, caching_dir = caching_dir,
                                convert_types = FALSE)
      result_data <- result_data %>% bind_rows(next_result)
    }
  }
  if (convert_types) {
    if (api == "query") {
      result_data <- result_data %>% apply_types()
    }
    if (api == "events" ||  api == "sessions") {
      result_data <- result_data %>% apply_types(timestamp_to_date = FALSE)
    }
  }
  return(result_data)
}


#' Send the query and receive the result
#'
#' @param query list generated by build_query()
#' @param token login token
#' @param use_csv logical to choose whether to fetch data via extra csv-request
#' @param api API endpoint (query, sessions, events)
#' @param caching logical Set TRUE to enable caching
#' @param caching_dir character Set directory for saving caching data
#' @return result as list with values data and meta
#' @importFrom magrittr %>%
#' @importFrom magrittr extract2
#' @importFrom dplyr first
#' @importFrom dplyr bind_rows
#' @importFrom dplyr if_else
#' @importFrom purrr map
#' @importFrom purrr flatten_chr
#' @importFrom purrr pmap
#' @importFrom purrr map_dfc
#' @importFrom stats setNames
#' @importFrom tibble tibble
#'

send_query_single <- function(query, token, use_csv, api, caching,
                              caching_dir) {

  fire_request <- function(url, token, query, caching, caching_dir) {
    if (caching == TRUE) {
      caching_dir <- fs::path_sanitize(caching_dir)
      request_with_url <- list(query, url)
      hash <- digest::digest(request_with_url)
      filename <- paste0("cache", "-",
                         query$date_from, "-",
                         query$date_to, "-",
                         if_else(use_csv == TRUE, "csv", "json"), "-",
                         format(query$offset, scientific = FALSE), "-",
                         hash, ".Rda") %>%
        fs::path_sanitize()
      filename <- paste0(caching_dir, "/", filename)
      if (file.exists(filename)) {
        load(filename)
      }else{
        result <- httr::POST(
          url = url,
          httr::add_headers(Authorization = paste0(token$token_type, " ",
                                                   token$access_token)),
          httr::add_headers("Accept-Encoding" = "gzip, deflate"),
          httr::content_type("application/vnd.api+json"),
          body = rjson::toJSON(query)
        )
        if (httr::status_code(result) == 200) {
          dir.create(caching_dir, showWarnings = FALSE)
          save(result, file = filename)
        }
      }
    } else{
      result <- httr::POST(
        url = url,
        httr::add_headers(Authorization = paste0(token$token_type, " ",
                                                 token$access_token)),
        httr::add_headers("Accept-Encoding" = "gzip, deflate"),
        httr::content_type("application/vnd.api+json"),
        body = rjson::toJSON(query)
      )
    }
    if(httr::status_code(result) != "200") {
      stop("Exit because of status code ", httr::status_code(result),
           "\nUrl war:\n", url,
           "\nRequest was: \n",
           rjson::toJSON(query))
    }
    return(result)
  }

  generate_column_names <- function(length_of_fields) {
    get_names_by_count <- function(name, count) {
      if (count == 1 || count == 0) {
        return(c(name))
      } else {
        seq <- 1:count
        names <- paste0(name, "_", seq)
        return(names)
      }
    }

    column_description <- tibble(
      name = colnames(length_of_fields),
      count = length_of_fields %>% as.numeric()
    )

    pmap(column_description, get_names_by_count) %>%
      flatten_chr() %>%
      return()
  }

  get_data_csv <- function() {
    query$format <- "csv"

    result <- fire_request(url, token, query,
                           caching = caching, caching_dir = caching_dir)

    if (httr::status_code(result) == 200) {
      csv <- httr::content(result, "text", encoding = "utf8")
      csv <- readr::read_csv(I(csv), col_types = readr::cols(.default = "c"))
      attr(csv, "spec") <- NULL
      csv
    }
  }

  url <- paste0(token$url, "/api/analytics/v1/", api, "/")

  # Remove max_lines before sending to piwik
  if (query$max_lines > 0 && query$max_lines < MAX_LINES_PER_REQUEST_ANALYTICS_API()) {
    query$limit <- query$max_lines
  }
  query$max_lines <- NULL

  query_meta <- query
  if (use_csv) {
    query_meta$limit <- 1
  }
  result <- fire_request(url, token, query_meta,
                         caching = caching, caching_dir = caching_dir)

  if (httr::status_code(result) == 200) {
    json <- httr::content(result, "text", encoding = "utf8")

    from_json <- json %>% rjson::fromJSON(simplify = FALSE)
    meta <- from_json %>% extract2("meta")

    if (!use_csv) {
      data <- from_json %>% extract2("data")

      column_names <- meta %>% extract2("columns")

      if (length(data) > 0) {
        # Get first row of result
        first_row <- data %>% first()
        length_of_fields <- first_row %>%
          map(length) %>%
          as.data.frame()
        colnames(length_of_fields) <- column_names

        column_names <- generate_column_names(length_of_fields)

        replace_null <- function(x) {
          if (is.null(x)) {
            NA
          } else {
            x
          }
        }

        data <- purrr::map_depth(data, 2, replace_null)
        data <- purrr::map_depth(data, 3, replace_null)
        data <- data %>%
          map_dfr(function(x) {
            x <- flatten(x)
            x <- set_names(x, column_names)
            x
          }) %>%
          as_tibble() %>%
          purrr::modify(as.character)
      } else {
        # Search result is empty
        data <- column_names %>%
          purrr::map_dfc(setNames, object = list(character()))
      }
    } else {
      data <- get_data_csv() %>%
        as_tibble()
    }
    return(list("data" = data, "meta" = meta))
  } else {
    warning(httr::content(result))
    return(NULL)
  }
}
