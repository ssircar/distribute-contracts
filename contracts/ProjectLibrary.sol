pragma solidity ^0.4.21;

import "./Project.sol";
import "./TokenRegistry.sol";
import "./ProjectRegistry.sol";
import "./Task.sol";
import "./library/PLCRVoting.sol";
import "./library/Division.sol";

/**
@title Function Library for Distribute Network Projects
@author Team: Jessica Marshall, Ashoka Finley
@dev This library is imported into all the Registries to manage project interactions
*/
library ProjectLibrary {

    // =====================================================================
    // EVENTS
    // =====================================================================

    event TokenRefund(address staker, uint256 refund);
    event ReputationRefund(address projectAddress, address staker, uint256 refund);

    // =====================================================================
    // UTILITY
    // =====================================================================

    /**
    @notice Returns true if `_staker` is either a token or reputation staker on project at `_projectAddress`
    @dev Used to define control access to relevant project functions
    @param _projectAddress Address of the project
    @param _staker Address of the staker
    @return A boolean representing staker status
    */
    function isStaker(address _projectAddress, address _staker) public view returns(bool) {
        Project project = Project(_projectAddress);
        return project.tokenBalances(_staker) > 0 || project.reputationBalances(_staker) > 0;
    }

    /**
    @notice Return true if the project at `_projectAddress` is fully staked with both tokens and reputation
    @dev Check project staked status
    @param _projectAddress Address of the project
    @return A boolean representing the project staked status
    */
    function isStaked(address _projectAddress) public view returns (bool) {
        Project project = Project(_projectAddress);
        return project.weiBal() >= project.weiCost() && project.reputationStaked() >= project.reputationCost();
    }

    /**
    @notice Return true if the current time is greater than the next deadline of the project at `_projectAddress`
    @dev Uses block.timestamp as a time variable. Note that this is subject to variability
    @param _projectAddress Address of the project
    @return A boolean representing wether the project has passed its next deadline.
    */
    function timesUp(address _projectAddress) public view returns (bool) {
        return (now > Project(_projectAddress).nextDeadline());
    }

    /**
    @notice Calculates the relative staking weight of `_address` on project at `_projectAddress.
    Weighting is caluclated by the proportional amount of both reputation and tokens that have been
    staked on the project.
    @dev Returns an average of the token staking and reputation staking.
    @param _projectAddress Address of the project
    @param _address Address of the staker
    @return The relaive weight of a staker as a whole integer
    */
    function calculateWeightOfAddress(
        address _projectAddress,
        address _address
    ) public view returns (uint256) {
        uint256 reputationWeight;
        uint256 tokenWeight;
        Project project = Project(_projectAddress);
        project.reputationStaked() != 0
            ? reputationWeight = Division.percent(
                project.reputationBalances(_address),
                project.reputationStaked(), 2)
            : reputationWeight = 0;
        project.tokensStaked() != 0
            ? tokenWeight = Division.percent(project.tokenBalances(_address), project.tokensStaked(), 2)
            : tokenWeight = 0;
        return (reputationWeight + tokenWeight) / 2;
    }

    // =====================================================================
    // STATE CHANGE
    // =====================================================================

    /**
    @notice Checks if project at `_projectAddress` is fully staked with both reputation and tokens.
    If the project is staked the project moves to state 2: Staked, and the next deadline is set.
    If the current time is passed the staking period, the project expires and is moved to state 8: Expired.
    @dev The nextDeadline value for the staked state is set in the project state variables.
    @param _projectAddress Address of the project.
    @return Returns a bool denoting the project is in the staked state.
    */
    function checkStaked(address _projectAddress) public returns (bool) {
        Project project = Project(_projectAddress);
        require(project.state() == 1);

        if(isStaked(_projectAddress)) {
            uint256 nextDeadline = now + project.stakedStatePeriod();
            project.setState(2, nextDeadline);
            return true;
        } else if(timesUp(_projectAddress)) {
            project.setState(8, 0);
            project.clearProposerStake();
        }
        return false;
    }

    /**
    @notice Checks if the project at `_projectAddress` has passed its next deadline, and if a
    valid task hash, meaning that the accounts who have staked on the project have succefully
    curated a list of tasks relating to project work. If a task hash exists the project is moved
    to state 3: Active and the next deadline is set. If no task hash exists the project is moved
    to state 7: Failed.
    @dev The nextDeadline value for the active state is set in the project state variables.
    @param _projectAddress Address of the project
    @param _taskHash Address of the top weighted task hash
    @return Returns a bool denoting the project is in the active state.
    */
    function checkActive(address _projectAddress, bytes32 _taskHash) public returns (bool) {
        Project project = Project(_projectAddress);
        require(project.state() == 2);

        if(timesUp(_projectAddress)) {
            uint256 nextDeadline;
            if(_taskHash != 0 ) {
                nextDeadline = now + project.activeStatePeriod();
                project.setState(3, nextDeadline);
                return true;
            } else {
                project.setState(7, 0);
            }
        }
        return false;
    }

    /**
    @notice Checks if the project at `_projectAddress` has passed its next deadline, and if it has
    moves the project to state 4: Validation. It interates through the project task list and checks if the
    project tasks have been marked complete. If a task hasn't been marked complete, its wei reward,
    is returned to the network balance, the task reward is zeroed.
    @dev This is an interative function and gas costs will vary depending on the number of tasks.
    @param _projectAddress Address of the project
    @param _tokenRegistryAddress Address of the systems Token Registry contract
    @param _distributeTokenAddress Address of the systems DistributeToken contract
    @return Returns a bool denoting if the project is in the validation state.
    */
    function checkValidate(
        address _projectAddress,
        address _tokenRegistryAddress,
        address _distributeTokenAddress
    ) public returns (bool) {
        Project project = Project(_projectAddress);
        require(project.state() == 3);

        if (timesUp(_projectAddress)) {
            uint256 nextDeadline = now + project.validateStatePeriod();
            project.setState(4, nextDeadline);
            TokenRegistry tr = TokenRegistry(_tokenRegistryAddress);
            for(uint i = 0; i < project.getTaskCount(); i++) {
                Task task = Task(project.tasks(i));
                if (task.complete() == false) {
                    uint reward = task.weiReward();
                    tr.revertWei(reward);
                    project.returnWei(_distributeTokenAddress, reward);
                    task.setTaskReward(0, 0, task.claimer());
                }
            }
            return true;
        }
        return false;
    }

    /**
    @notice Checks if the project at `_projectAddress` has passed its next deadline, and if it has
    moves the project to state 5: Voting. It iterates through the project task list and checks if
    there are opposing validators for each task. If there are then its starts a plcr for each
    disputed task, otherwise it marks the task claimable by the validators, and by the reputation holder
    who claimed the task if the validators approved the task.
    @dev This is an interative function and gas costs will vary depending on the number of tasks.
    @param _projectAddress Address of the project
    @param _tokenRegistryAddress Address of the systems token registry contract
    @param _distributeTokenAddress Address of the systems token contract
    @param _plcrVoting Address of the systems PLCR Voting contract
    @return Returns a bool denoting if the project is in the voting state.
    */
    function checkVoting(
        address _projectAddress,
        address _tokenRegistryAddress,
        address _distributeTokenAddress,
        address _plcrVoting
    ) public returns (bool) {
        Project project = Project(_projectAddress);
        require(project.state() == 4);

        if (timesUp(_projectAddress)) {
            uint256 nextDeadline = now + project.voteCommitPeriod() + project.voteRevealPeriod();
            project.setState(5, nextDeadline);
            TokenRegistry tr = TokenRegistry(_tokenRegistryAddress);
            PLCRVoting plcr = PLCRVoting(_plcrVoting);
            for(uint i = 0; i < project.getTaskCount(); i++) {
                Task task = Task(project.tasks(i));
                if (task.complete()) {
                    if (task.opposingValidator()) { // there is an opposing validator, poll required
                        uint pollNonce = plcr.startPoll(51, project.voteCommitPeriod(), project.voteRevealPeriod());
                        task.setPollId(pollNonce); // function handles storage of voting pollId
                    } else {
                        bool repClaim = task.markTaskClaimable(true);
                        if (!repClaim) {
                            uint reward = task.weiReward();
                            tr.revertWei(reward);
                            project.returnWei(_distributeTokenAddress, reward);
                        }
                    }
                }
            }
        }
        return false;
    }

    /**
    @notice Checks if the project at `_projectAddress` has passed its next deadline. It iterates through
    the project task list, and checks the projects which have polls to see the poll state. If the poll has
    passed the task is marked claimable by both the approve validators and the task claimer. Otherwise
    the task is marked claimable for the deny validators, and the task reward is returned to the networks
    wei balance. The amount of tasks that have passed is then calculated. If the total weighting of those
    tasks passes the project passThreshold then the project is moved to state 6: Complete, otherwise it
    moves to state 7: Expired.
    @dev The project pass passThreshold is set in the project state variables
    @param _projectAddress Address of the project
    @param _tokenRegistryAddress Address of the systems token registry contract
    @param _distributeTokenAddress Address of the systems token contract
    @param _plcrVoting Address of the systems PLCR Voting contract
    @return Returns a bool denoting if the project is its final state.
    */
    function checkEnd(
        address _projectAddress,
        address _tokenRegistryAddress,
        address _distributeTokenAddress,
        address _plcrVoting
    ) public returns (bool) {
        Project project = Project(_projectAddress);
        require(project.state() == 5);

        if (timesUp(_projectAddress)) {
            TokenRegistry tr = TokenRegistry(_tokenRegistryAddress);
            PLCRVoting plcr = PLCRVoting(_plcrVoting);
            for (uint i = 0; i < project.getTaskCount(); i++) {
                Task task = Task(project.tasks(i));
                if (task.complete() && task.opposingValidator()) {      // check tasks with polls only
                    if (plcr.pollEnded(task.pollId())) {
                        if (plcr.isPassed(task.pollId())) {
                            task.markTaskClaimable(true);
                        } else {
                            task.markTaskClaimable(false);
                            uint reward = task.weiReward();
                            tr.revertWei(reward);
                            project.returnWei(_distributeTokenAddress, reward);
                        }
                    }
                }
            }
            calculatePassAmount(_projectAddress);
            project.passAmount() >= project.passThreshold()
                ? project.setState(6, 0)
                : project.setState(7, 0);
            return true;
        }
        return false;
    }

    // =====================================================================
    // VALIDATION
    // =====================================================================

    /**
    @notice Stake tokens on whether the task at index `i` has been successful or not. Validator
    `_validator` can validate either approve or deny, with `tokens` tokens.
    @param _projectAddress Address of the project
    @param _validator Address of the validator
    @param _index Index of the task in the projects task array
    @param _tokens Amount of tokens validator is staking
    @param _validationState Bool representing validators choice.s
    */
    function validate(
        address _projectAddress,
        address _validator,
        uint256 _index,
        uint256 _tokens,
        bool _validationState
    ) public {
        require(_tokens > 0);
        Project project = Project(_projectAddress);
        require(project.state() == 4);

        Task task = Task(project.tasks(_index));
        require(task.complete() == true);
        _validationState
            ? task.setValidator(_validator, 1, _tokens)
            : task.setValidator(_validator, 0, _tokens);
    }

    /**
    @notice Calculates the amount of tasks that have passed for project at `_projectAddress`
    @param _projectAddress Address of the project
    @return Sum of the weightings of the task which have passed.
    */
    function calculatePassAmount(address _projectAddress) public returns (uint){
        Project project = Project(_projectAddress);
        require(project.state() == 5);

        uint totalWeighting;
        for (uint i = 0; i < project.getTaskCount(); i++) {
            Task task = Task(project.tasks(i));
            if (task.claimableByRep()) { totalWeighting += task.weighting(); }
        }
        project.setPassAmount(totalWeighting);
        return totalWeighting;
    }

    // =====================================================================
    // TASK
    // =====================================================================

    /**
    @notice Claim the task reward from task at index `_index` from the task array of project at
    `_projectAddress`. If task is claimable by the reputation holder, Clears the task reward, and
    transfers the wei reward to the task claimer. Returns the reputation reward for the claimer.
    @param _projectAddress Address of the project
    @param _index Index of the task in project task array
    @return The amount of reputation the claimer staked on the task
    */
    function claimTaskReward(
        address _projectAddress,
        uint256 _index,
        address _claimer
    ) public returns (uint256) {
        Project project = Project(_projectAddress);
        Task task = Task(project.tasks(_index));
        require(task.claimer() == _claimer && task.claimableByRep());

        uint256 weiReward = task.weiReward();
        uint256 reputationReward = task.reputationReward();
        task.setTaskReward(0, 0, _claimer);
        project.transferWeiReward(_claimer, weiReward);
        return reputationReward;
    }

    // =====================================================================
    // STAKER
    // =====================================================================

    /**
    @notice Refund both either reputation or token staker `_staker` for project at address `_projectAddress`
    @dev Calls internal functions to handle either staker case.
    @param _projectAddress Address of the project
    @param _staker Address of the staker
    @return The amount to be refunded to the staker.
    */
    function refundStaker(address _projectAddress, address _staker) public returns (uint256) {
        Project project = Project(_projectAddress);
        require(project.state() == 6 || project.state() == 8);

        if (project.isTR(msg.sender)) {
            return handleTokenStaker(project, _staker);
        } else if (project.isRR(msg.sender)) {
            return handleReputationStaker(project, _staker);
        } else {
            return 0;
        }
    }

    /**
    @notice Handle token staker at _address on project `_project`, stake reward is multiplied by the pass amount.
    @dev Only used internally.
    @param _project Project instance
    @param _staker Token staker address
    @return The token refund to be returned to the token staker.
    */
    function handleTokenStaker(Project _project, address _staker) internal returns (uint256) {
        uint256 refund;
        // account for proportion of successful tasks
        if(_project.tokensStaked() != 0) {
            refund = _project.tokenBalances(_staker) * _project.passAmount() / 100;
        }
        emit TokenRefund(_staker, refund);
        return refund;
    }

    /**
    @notice Handle reputation staker at _address on project `_project`, stake reward is multiplied by the pass amount.
    @dev Only used internally.
    @param _project Project instance
    @param _staker Reputation staker address
    @return The reputation refund to be returned to the reputation staker.
    */
    function handleReputationStaker(Project _project, address _staker) internal returns (uint256) {
        uint256 refund;
        if(_project.reputationStaked() != 0) {
            refund = _project.reputationBalances(_staker) * _project.passAmount() / 100;
        }
        emit ReputationRefund(address(_project), _staker, refund);
        return refund;
    }
}
