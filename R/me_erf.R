out_me <- function(A0, A1, X0, X1, Y0, Y1_me, Y1_true, 
                   a.vals = seq(min(A0), max(A0), length = 100), bw = 1, 
                   sl.lib, ...) {
  
  n1 <- nrow(X1)
  n0 <- nrow(X0)
  
  S <- rep(c(0,1), times = c(n0, n1))
  X <- rbind(X0, X1)
  A <- c(A0, A1)
  
  n <- n1 + n0
  m <- ncol(X)
  
  ## outcome model
  mumod <- SuperLearner(Y = Y0, X = data.frame(X0, A = A0),
                        family = family, SL.library = sl.lib)
  muhat <- mumod$SL.predict

  muhat.mat <- sapply(A0, function(a.tmp, ...) {

    xa.tmp <- data.frame(X0, A = a.tmp)
    predict(mumod, newdata = xa.tmp)$pred

  })

  mhat <- colMeans(muhat.mat)
  int0.mat <- matrix(rep(mhat, n0), byrow = TRUE, nrow = n0)
  
  ## bias model
  bias <- c(Y1_me - Y1_true)
  etamod <- SuperLearner(Y = bias, X = data.frame(X1, A = A1),
                         family = family, SL.library = sl.lib)

  etahat.mat <- sapply(A1, function(a.tmp, ...) {

    xa.tmp <- data.frame(X0, A = a.tmp)
    predict(mumod, newdata = xa.tmp)$pred

  })

  ehat <- colMeans(etahat.mat)
  int1.mat <- matrix(rep(ehat, n1), byrow = TRUE, nrow = n1)
  
  ## weight model
  
  # standardize a
  astar_0 <- c(A0 - mean(A0))/var(A0)
  astar2_0 <- c((A0 - mean(A0))^2/var(A0) - 1)
  astar_1 <- c(A1 - mean(A1))/var(A1)
  astar2_1 <- c((A1 - mean(A1))^2/var(A1) - 1)
  
  astar <- c(astar_0, astar_1)
  astar2 <- c(astar2_0, astar2_1)
  
  cmat <- cbind((1 - S)*X*astar, (1 - S)*astar2,
                S*X*astar, S*astar2, S*X, (1-S)*X)
  target <- c(rep(0, 2*(m + 1)), n1*colMeans(X0), n0*colMeans(X0))
  
  mod <- calibrate(cmat = cmat, target = target)
  ipw <- mod$weights
  
  psi0 <- c(ipw[S == 0]*Y0)
  psi1 <- c(ipw[S == 1]*c(Y1_me - Y1_true))
  
  ## kernel weighted least squares
  # out0 <- sapply(a.vals, kern_ipw, a = A0, psi = psi0, bw = bw, se.fit = TRUE)
  # out1 <- sapply(a.vals, kern_ipw, a = A1, psi = psi1, bw = bw, se.fit = TRUE)
  
  ## spline method
  out0 <- spl_ipw(a = A0, psi = psi0, a.vals = a.vals, int.mat = int.mat, df = 6, se.fit = TRUE)
  out1 <- spl_ipw(a = A1, psi = psi1, a.vals = a.vals, int.mat = int.mat, df = 6, se.fit = TRUE)
  
  estimate <- out0[1,] - out1[1,]
  se <- sqrt(out0[2,] + out1[2,])
  
  return(list(estimate = estimate, se = se, ipw0 = ipw[S == 0], ipw1 = ipw[S == 1]))
  
}

out_naive <- function(A0, X0, Y0, a.vals = seq(min(A0), max(A0), length = 100), bw = 1,...) {
  
  n0 <- nrow(X0)
  m <- ncol(X0)
  
  ## weight model
  
  # standardize a
  astar <- c(A0 - mean(A0))/var(A0)
  astar2 <- c((A0 - mean(A0))^2/var(A0) - 1)
  
  cmat <- cbind(X0*astar, astar2)
  target <- rep(0, m + 1)
  
  mod <- calibrate(cmat = cmat, target = target)
  ipw <- mod$weights
  
  ## kernel weighted least squares
  psi0 <- c(ipw*Y0)
  out <- sapply(a.vals, kern_ipw, a = A0, psi = psi0, bw = bw, se.fit = TRUE)
  
  estimate <- out[1,]
  se <- sqrt(out[2,])
  
  return(list(estimate = estimate, se = se, ipw = ipw))
  
}

# Kernel weighted least squares
kern_ipw <- function(a.new, a, psi, bw = 1, se.fit = FALSE) {
  
  n <- length(a)
  
  # Gaussian Kernel
  a.std <- (a - a.new) / bw
  k.std <- dnorm(a.std) / bw
  g.std <- cbind(1, a.std)
  
  b <- lm(psi ~ -1 + g.std, weights = k.std)$coefficients
  mu <- unname(b[1])
  
  if (se.fit) {
    
    eta <- c(g.std %*% b)
    U <- solve(crossprod(g.std, k.std*g.std))
    V <- cbind(k.std * (psi - eta),
               a.std * k.std * (psi - eta))
    Sig <- U %*% crossprod(V) %*% U
    
    return(c(mu = mu, sig2 = unname(Sig[1,1])))
    
    
  } else
    return(mu)
  
}

# Spline -- IPW
spl_ipw <- function(a, psi, a.vals, df = 4, se.fit = FALSE) {
  
  n <- length(a)
  
  # spline model
  fmla <- as.formula(paste0("psi ~ -1 + ns(a, df =", df, ", intercept = TRUE)"))
  mod <- lm(fmla, data.frame(psi = psi, a = a))
  mu <- predict(mod, newdata = data.frame(a = a.vals), se.fit = se.fit, type = "response")
  
  if (se.fit) 
    return(rbind(mu = mu$fit, sig2 = mu$se.fit^2))
  else
    return(mu)
  
}

# Spline method? I am not sure what I was doing with this...
spl_ipw2 <- function(a, psi, a.vals = NULL, df = 4, weights = NULL, se.fit = FALSE,  int.mat = NULL) {
  
  n <- length(a)
  
  if (is.null(weights))
    weights <- rep(1, times = n)
  
  # Regression
  g.std <- ns(a, df = df, intercept = TRUE)
  g.vals <- predict(g.std, newx = a.vals)
  
  mod <- lm(psi ~ g.std, weights = weights)
  mu <- g.vals%*%mod$coefficients
  
  if (se.fit & !is.null(int.mat) & !is.null(a.vals)) {
    
    eta <- mod$fitted.values
    V <- matrix(NA, ncol = ncol(g.std))
    
    for (i in 1:ncol(g.std)) {
      
      g <- g.std[,o]
      intfn.mat <- matrix(rep(g, n), byrow = TRUE, nrow = n) * int.mat
      int <- rowMeans(intfn.mat)
      V[,i] <- weights*(g * (psi - eta) + int)
      
    }
    
    U <- solve(crossprod(g.std, weights*g.std))
    sig2 <- t(g.vals) %*% U %*% crossprod(V) %*% U %*% g.vals
    
    return(rbind(mu = mu, sig2 = sig2))
    
    
  } else
    return(mu)
  
}