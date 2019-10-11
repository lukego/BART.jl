###############################################################################
##### Gibbs and Metropolis-Hastings Proposals
###############################################################################

## Probability a Node is a Branch
function probgrow(d::Int64, bm::BartModel)
  bm.hypers.α * (1.0 + d) ^ (-bm.hypers.β)
end

## Prior probability of a Tree
function log_tree_prior(tree::Tree, bm::BartModel)
  if isa(tree.root, Leaf)
    d = depth(tree.root, tree)
    return log(1 - probgrow(d, bm))
  end
  lp = log(probgrow(depth(tree.root, tree), bm))
  log_tree_prior(tree.root.left, tree, bm, lp) +
    log_tree_prior(tree.root.right, tree, bm, lp)
end

function log_tree_prior(trees::Vector{Tree}, bm::BartModel)
  ltp = 0
  for tree in trees
    ltp += log_tree_prior(tree, bm)
  end
  ltp
end

function log_tree_prior(branch::Branch, tree::Tree, bm::BartModel, lp::Float64)
  d = depth(branch, tree)
  lp += log(probgrow(d, bm))
  log_tree_prior(branch.left, tree, bm, lp) +
    log_tree_prior(branch.right, tree, bm, lp)
end

function log_tree_prior(leaf::Leaf, tree::Tree, bm::BartModel, lp::Float64)
  d = depth(leaf, tree)
  lp + log(1 - probgrow(d, bm))
end

## Probability that an observtion goes left at a given Branch
function probleft(x::Vector{Float64}, branch::Branch, tree::Tree)
  1 / (1 + exp((x[branch.var] - branch.cut) / tree.λ))
end

function probleft(X::Matrix{Float64}, branch::Branch, tree::Tree)
  1 ./ (1 .+ exp.((X[:,branch.var] .- branch.cut) ./ tree.λ))
end

## Probability that observations end up in each Leaf
function leafprob(x::Vector{Float64}, tree::Tree)
  if isa(tree.root, Leaf)
    return 1.0
  end
  S = Float64[]
  goesleft = probleft(x, tree.root, tree)
  goesright = 1 - goesleft
  leafprob(x, tree.root.left, tree, goesleft, S)
  leafprob(x, tree.root.right, tree, goesright, S)
end

function leafprob(x::Vector{Float64}, branch::Branch, tree::Tree, psi::Float64, S::Vector{Float64})
  goesleft = psi * probleft(x, branch, tree)
  goesright = psi - goesleft
  leafprob(x, branch.left, tree, goesleft, S)
  leafprob(x, branch.right, tree, goesright, S)
end

function leafprob(x::Vector{Float64}, leaf::Leaf, tree::Tree, psi::Float64, S::Vector{Float64})
  push!(S, psi)
end

function leafprob(X::Matrix{Float64}, tree::Tree, bm::BartModel)
  S = zeros(bm.td.n, tree.ss.Lt)
  for i in 1:bm.td.n
    S[i,:] .= leafprob(X[i,:], tree)
  end
  S
end

function leafprob(X::Matrix{Float64}, tree::Tree)
  n = size(X, 1)
  S = zeros(n, tree.ss.Lt)
  for i in 1:n
    S[i,:] .= leafprob(X[i,:], tree)
  end
  S
end

## Draw a new cut value for the proposed split
function drawcut(leaf::Leaf, var::Int64, tree::Tree, bm::BartModel)
  branch = leaf
  lower = [bm.td.xmin[:,var][1]]
  upper = [bm.td.xmax[:,var][1]]
  check = branch == tree.root ? false : true
  while check
    left = isleft(branch, tree)
    branch = parent(branch, tree)
    check = branch == tree.root ? false : true
    if (branch.var == var)
      check
      if (left)
        upper = push!(upper, branch.cut)
      else
        lower = push!(lower, branch.cut)
      end
    end
  end
  lower = maximum(lower)
  upper = minimum(upper)
  rand(Uniform(lower, upper))
end

## If the birthproposal is accepted
## grow the Leaf into a Branch with two new Leafs
function birthleaf!(leaf::Leaf, tree::Tree, branch::Branch)
  if isa(tree.root, Leaf)
    tree.root = branch
  else
    parentnode = parent(leaf, tree)
    if parentnode.left == leaf
      parentnode.left = branch
    else
      parentnode.right = branch
    end
  end
end

## Probability of making a birth proposal
## If the tree only has a root node, a birth proposal has to be made
## Otherwise randomly choose a Birth or Death proposal with probability 0.5
function birthprob(tree::Tree)
  isa(tree.root, Leaf) ? 1.0 : 0.5
end

function birthprob(S::Matrix{Float64})
  size(S, 2) == 1 ? 1.0 : 0.5
end

## The log ratio of the transition probabilities for a birth proposal
function log_birth_trans(tree::Tree, S_prime::Matrix{Float64})
  # Probability of transitioning from proposed Tree back to the current Tree
  numr = (1 - birthprob(S_prime)) / (tree.ss.Lt - 1)
  # Probability of transitioning from the current Tree to the proposed Tree
  denomr = birthprob(tree) / tree.ss.Lt
  log(numr) - log(denomr)
end

## The log ratio of the tree probabilities
function log_birth_tree(node::Node, tree::Tree, bm::BartModel)
  d = depth(node, tree)
  numr = probgrow(d, bm) * (1 - probgrow(d + 1, bm)) ^ 2
  denomr = 1 - probgrow(d, bm)
  log(numr) - log(denomr)
end

## Compute the mariginal log likelihood of the current Tree residuals
function mll(rt::Vector{Float64}, ss::SuffStats, bs::BartState, bm::BartModel)
  mll = 0.5 * logdet(2 * pi * ss.Ω)
  mll -= 0.5 * bm.td.n * log(2 * pi * bs.σ^2)
  mll -= 0.5 * ss.Lt * log(2 * pi * bm.hypers.τ)
  mll -= 0.5 * dot(rt, rt) / bs.σ^2
  mll += 0.5 * dot(ss.rhat, ss.Ω * ss.rhat)
  mll
end

## Conduct a Birth proposal
function birthproposal!(tree::Tree, rt::Vector{Float64}, bs::BartState, bm::BartModel)
  leaves = leafnodes(tree)
  index = rand(1:length(leaves))
  leaf = leaves[index]
  newvar = rand(1:bm.td.p)
  newcut = drawcut(leaf, newvar, tree, bm)
  branch = Branch(newvar, newcut, Leaf(0.0), Leaf(0.0))
  goesleft = tree.S[:,index] .* probleft(bm.td.X, branch, tree)
  goesright = tree.S[:,index] .- goesleft
  if size(tree.S, 2) == 1
    S_prime = hcat(goesleft, goesright)
  else
    indices = [index, index + 1]
    S_prime = zeros(bm.td.n, length(leaves) + 1)
    S_prime[:,indices] = hcat(goesleft, goesright)
    S_prime[:,setdiff(1:end, indices)] = tree.S[:,setdiff(1:end, index)]
  end
  tree.ss = suffstats(rt, tree.S, bs, bm)
  ss_prime = suffstats(rt, S_prime, bs, bm)
  mloglikratio = mll(rt, ss_prime, bs, bm) - mll(rt, tree.ss, bs, bm)
  treeratio = log_birth_tree(leaf, tree, bm)
  transratio = log_birth_trans(tree, S_prime)
  logr = mloglikratio + treeratio + transratio
  if log(rand()) < logr
    birthleaf!(leaf, tree, branch)
    tree.S = S_prime
    tree.ss = ss_prime
  end
end

## The log ratio of the transition probabilities for a Death proposal
function log_death_trans(tree::Tree, S_prime::Matrix{Float64})
  numr = birthprob(S_prime) / (tree.ss.Lt - 1)
  denomr = (1 - birthprob(tree)) / (tree.ss.Lt - 1)
  log(numr) - log(denomr)
end

## The log ratio of the Tree probabilities
function log_death_tree(node::Node, tree::Tree, bm::BartModel)
  -1.0*log_birth_tree(node, tree, bm)
end

## If doing a Death proposal, kill two Leaf Nodes of
## a randomly selected Branch and turn the Branch into a Leaf
function deathbranch!(branch::Branch, tree::Tree)
  if tree.root == branch
    tree.root = Leaf(0.0)
  else
    parentnode = parent(branch, tree)
    if parentnode.left == branch
      parentnode.left = Leaf(0.0)
    else
      parentnode.right = Leaf(0.0)
    end
  end
end

## Conduct a Death proposal
function deathproposal!(tree::Tree, rt::Vector{Float64}, bs::BartState, bm::BartModel)
  branch = rand(onlyparents(tree))
  indexes = findall(x -> (x == branch.left) || (x == branch.right), leafnodes(tree))
  S_prime = copy(tree.S)
  S_prime[:,indexes[1]] = sum(tree.S[:,indexes], dims = 2)
  S_prime = S_prime[:,1:end .!= indexes[2]]
  tree.ss = suffstats(rt, tree.S, bs, bm)
  ss_prime = suffstats(rt, S_prime, bs, bm)
  mloglikratio = mll(rt, ss_prime, bs, bm) - mll(rt, tree.ss, bs, bm)
  treeratio = log_death_tree(branch, tree, bm)
  transratio = log_death_trans(tree, S_prime)
  logr = mloglikratio + treeratio + transratio
  if log(rand()) < logr
    deathbranch!(branch, tree)
    tree.S = S_prime
    tree.ss = ss_prime
  end
end

## Function to perform Metropolis-Hastings step for a single Tree update
function drawT!(tree::Tree, rt::Vector{Float64}, bs::BartState, bm::BartModel)
  if rand() < birthprob(tree)
    birthproposal!(tree, rt, bs, bm)
  else
    deathproposal!(tree, rt, bs, bm)
  end
end

## Function to perform Metropolis-Hastings step to update λ on a single Tree
function drawλ!(tree::Tree, rt::Vector{Float64}, bs::BartState, bm::BartModel)
  lp_λ = logpdf(Exponential(bm.hypers.λmean), tree.λ)
  log_λ = log(tree.λ)
  log_λprime = log_λ + rand(Uniform(-1, 1))
  tree.λ = exp(log_λprime)
  lp_λprime = logpdf(Exponential(bm.hypers.λmean), tree.λ)
  S_prime = leafprob(bm.td.X, tree, bm)
  ss_prime = suffstats(rt, S_prime, bs, bm)
  logr = mll(rt, ss_prime, bs, bm) + lp_λprime + log_λprime -
    (mll(rt, tree.ss, bs, bm) + lp_λ + log_λ)
  if log(rand()) < logr
    tree.S = S_prime
    tree.ss = ss_prime
  else
    tree.λ = exp(log_λ)
  end
end

## Gibbs step to update leaf parameters for a single Tree
function drawμ!(tree::Tree, rt::Vector{Float64}, bs::BartState, bm::BartModel)
  Omega = inv(transpose(tree.S) * tree.S / bs.σ^2 + I / bm.hypers.τ)
  rhat = transpose(tree.S) * rt / bs.σ^2
  newμ = rand(MvNormal(Omega * rhat, Symmetric(Omega)))
  leaves = leafnodes(tree)
  for l in 1:length(leaves)
    leaves[l].μ = newμ[l]
  end
end

function drawtrees!(bs::BartState, bm::BartModel)
  for tree in bs.trees
    fhat_t = bs.fhat .- predict(tree)
    rt = resp(bm.td.resp) .- fhat_t
    drawT!(tree, rt, bs, bm)
    drawλ!(tree, rt, bs, bm)
    drawμ!(tree, rt, bs, bm)
    bs.fhat = fhat_t .+ predict(tree)
  end
  bs.fhat = predict(bs, bm)
end

function drawz!(bs::BartState, bm::BartModel)
  for i in 1:bm.td.n
    if bm.td.resp.y[i] == 1
      bm.td.resp.z[i] = rand(Truncated(Normal(bs.fhat[i]), 0, Inf))
    else
      bm.td.resp.z[i] = rand(Truncated(Normal(bs.fhat[i]), -Inf, 0))
    end
  end
end

## Gibbs step to update error variance
function drawσ!(bs::BartState, bm::BartModel)
  a = 0.5 * (bm.hypers.ν + bm.td.n)
  b = 0.5 * (bm.hypers.ν * bm.hypers.δ + sum((resp(bm.td.resp) - bs.fhat).^2))
  bs.σ = sqrt(rand(InverseGamma(a, b)))
end
